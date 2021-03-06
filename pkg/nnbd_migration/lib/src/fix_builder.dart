// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/flow_analysis/flow_analysis.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/null_safety_understanding_flag.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_provider.dart';
import 'package:analyzer/src/error/best_practices_verifier.dart';
import 'package:analyzer/src/generated/element_type_provider.dart';
import 'package:analyzer/src/generated/migration.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:nnbd_migration/instrumentation.dart';
import 'package:nnbd_migration/nnbd_migration.dart';
import 'package:nnbd_migration/src/decorated_class_hierarchy.dart';
import 'package:nnbd_migration/src/decorated_type.dart';
import 'package:nnbd_migration/src/edit_plan.dart';
import 'package:nnbd_migration/src/fix_aggregator.dart';
import 'package:nnbd_migration/src/nullability_node.dart';
import 'package:nnbd_migration/src/utilities/permissive_mode.dart';
import 'package:nnbd_migration/src/utilities/resolution_utils.dart';
import 'package:nnbd_migration/src/variables.dart';

/// Problem reported by [FixBuilder] when encountering a compound assignment
/// for which the combination result is nullable.  This occurs if the compound
/// assignment resolves to a user-defined operator that returns a nullable type,
/// but the target of the assignment expects a non-nullable type.  We need to
/// add a null check but it's nontrivial to do so because we would have to
/// rewrite the assignment as an ordinary assignment (e.g. change `x += y` to
/// `x = (x + y)!`), but that might change semantics by causing subexpressions
/// of the target to be evaluated twice.
///
/// TODO(paulberry): consider alternatives.
/// See https://github.com/dart-lang/sdk/issues/38675.
class CompoundAssignmentCombinedNullable implements Problem {
  const CompoundAssignmentCombinedNullable();
}

/// Problem reported by [FixBuilder] when encountering a compound assignment
/// for which the value read from the target of the assignment has a nullable
/// type.  We need to add a null check but it's nontrivial to do so because we
/// would have to rewrite the assignment as an ordinary assignment (e.g. change
/// `x += y` to `x = x! + y`), but that might change semantics by causing
/// subexpressions of the target to be evaluated twice.
///
/// TODO(paulberry): consider alternatives.
/// See https://github.com/dart-lang/sdk/issues/38676.
class CompoundAssignmentReadNullable implements Problem {
  const CompoundAssignmentReadNullable();
}

/// This class runs the analyzer's resolver over the code being migrated, after
/// graph propagation, to figure out what changes need to be made.  It doesn't
/// actually make the changes; it simply reports what changes are necessary
/// through abstract methods.
class FixBuilder {
  /// The type provider providing non-nullable types.
  final TypeProvider typeProvider;

  final Map<AstNode, NodeChange> changes = {};

  final Map<AstNode, Set<Problem>> problems = {};

  /// The NNBD type system.
  final TypeSystemImpl _typeSystem;

  /// Variables for this migration run.
  final Variables _variables;

  /// The file being analyzed.
  final Source source;

  ResolverVisitor _resolver;

  /// The listener to which exceptions should be reported.
  final NullabilityMigrationListener listener;

  /// The compilation unit for which fixes are being built.
  final CompilationUnit unit;

  final MigrationResolutionHooksImpl migrationResolutionHooks;

  /// Parameter elements for which an explicit type should be added, and what
  /// that type should be.
  final Map<ParameterElement, DartType> _addedParameterTypes = {};

  factory FixBuilder(
      Source source,
      DecoratedClassHierarchy decoratedClassHierarchy,
      TypeProvider typeProvider,
      TypeSystemImpl typeSystem,
      Variables variables,
      LibraryElement definingLibrary,
      NullabilityMigrationListener listener,
      CompilationUnit unit) {
    var migrationResolutionHooks = MigrationResolutionHooksImpl();
    return FixBuilder._(
        decoratedClassHierarchy,
        _makeNnbdTypeSystem(
            (typeProvider as TypeProviderImpl).asNonNullableByDefault,
            typeSystem,
            migrationResolutionHooks),
        variables,
        source,
        definingLibrary,
        listener,
        unit,
        migrationResolutionHooks);
  }

  FixBuilder._(
      DecoratedClassHierarchy decoratedClassHierarchy,
      this._typeSystem,
      this._variables,
      this.source,
      LibraryElement definingLibrary,
      this.listener,
      this.unit,
      this.migrationResolutionHooks)
      : typeProvider = _typeSystem.typeProvider {
    migrationResolutionHooks._fixBuilder = this;
    // TODO(paulberry): make use of decoratedClassHierarchy
    assert(_typeSystem.isNonNullableByDefault);
    assert((typeProvider as TypeProviderImpl).isNonNullableByDefault);
    var inheritanceManager = InheritanceManager3();
    // TODO(paulberry): is it a bad idea to throw away errors?
    var errorListener = AnalysisErrorListener.NULL_LISTENER;
    // TODO(paulberry): once the feature is no longer experimental, change the
    // way we enable it in the resolver.
    // ignore: invalid_use_of_visible_for_testing_member
    var featureSet = FeatureSet.forTesting(
        sdkVersion: '2.6.0', additionalFeatures: [Feature.non_nullable]);
    _resolver = ResolverVisitorForMigration(
        inheritanceManager,
        definingLibrary,
        source,
        typeProvider,
        errorListener,
        _typeSystem,
        featureSet,
        migrationResolutionHooks);
  }

  /// Visits the entire compilation [unit] using the analyzer's resolver and
  /// makes note of changes that need to be made.
  void visitAll() {
    try {
      NullSafetyUnderstandingFlag.enableNullSafetyTypes(() {
        ElementTypeProvider.current = migrationResolutionHooks;
        unit.accept(_FixBuilderPreVisitor(this));
        unit.accept(_resolver);
        unit.accept(_FixBuilderPostVisitor(this));
      });
    } catch (exception, stackTrace) {
      if (listener != null) {
        listener.reportException(source, unit, exception, stackTrace);
      } else {
        rethrow;
      }
    } finally {
      ElementTypeProvider.current = const ElementTypeProvider();
    }
  }

  /// Called whenever an AST node is found that can't be automatically fixed.
  void _addProblem(AstNode node, Problem problem) {
    var newlyAdded = (problems[node] ??= {}).add(problem);
    assert(newlyAdded);
  }

  /// Computes the type that [element] will have after migration.
  ///
  /// If [targetType] is present, and [element] is a class member, it is the
  /// type of the class within which [element] is being accessed; this is used
  /// to perform the correct substitutions.
  DartType _computeMigratedType(Element element) {
    element = element.declaration;
    if (element is ClassElement || element is TypeParameterElement) {
      return typeProvider.typeType;
    } else if (element is PropertyAccessorElement &&
        element.isSynthetic &&
        !element.variable.isSynthetic) {
      var variableType = _variables
          .toFinalType(_variables.decoratedElementType(element.variable));
      if (element.isSetter) {
        return FunctionTypeImpl(
            returnType: typeProvider.voidType,
            typeFormals: [],
            parameters: [
              ParameterElementImpl.synthetic(
                  'value', variableType, ParameterKind.REQUIRED)
            ],
            nullabilitySuffix: NullabilitySuffix.none);
      } else {
        return FunctionTypeImpl(
            returnType: variableType,
            typeFormals: [],
            parameters: [],
            nullabilitySuffix: NullabilitySuffix.none);
      }
    } else {
      return _variables.toFinalType(_variables.decoratedElementType(element));
    }
  }

  /// Returns the [NodeChange] object accumulating changes for the given [node],
  /// creating it if necessary.
  NodeChange _getChange(AstNode node) =>
      changes[node] ??= NodeChange.create(node);

  /// Determines whether the given [node], which is a null-aware method
  /// invocation, property access, or index expression, should remain null-aware
  /// after migration.
  bool _shouldStayNullAware(Expression node) {
    Expression target;
    if (node is PropertyAccess) {
      target = node.target;
    } else if (node is MethodInvocation) {
      target = node.target;
    } else {
      throw StateError('Unexpected expression type: ${node.runtimeType}');
    }
    if (!_typeSystem.isPotentiallyNullable(target.staticType)) {
      (_getChange(node) as NodeChangeForNullAware).removeNullAwareness = true;
      return false;
    }
    return true;
  }

  static TypeSystemImpl _makeNnbdTypeSystem(
      TypeProvider nnbdTypeProvider,
      TypeSystemImpl typeSystem,
      MigrationResolutionHooksImpl migrationResolutionHooks) {
    // TODO(paulberry): do we need to test both possible values of
    // strictInference?
    return TypeSystemImpl(
        implicitCasts: typeSystem.implicitCasts,
        isNonNullableByDefault: true,
        strictInference: typeSystem.strictInference,
        typeProvider: nnbdTypeProvider);
  }
}

/// Fix reason object when adding a null check because of an explicit hint.
class FixReason_NullCheckHint implements SimpleFixReasonInfo {
  @override
  final CodeReference codeReference;

  FixReason_NullCheckHint(this.codeReference);

  @override
  String get description => 'Null check hint';
}

/// Implementation of [MigrationResolutionHooks] that interfaces with
/// [FixBuilder].
class MigrationResolutionHooksImpl implements MigrationResolutionHooks {
  FixBuilder _fixBuilder;

  final Expando<List<CollectionElement>> _collectionElements = Expando();

  final Expando<bool> _shouldStayNullAware = Expando();

  FlowAnalysis<AstNode, Statement, Expression, PromotableElement, DartType>
      _flowAnalysis;

  @override
  void freshTypeParameterCreated(TypeParameterElement newTypeParameter,
      TypeParameterElement oldTypeParameter) {
    DecoratedTypeParameterBounds.current.put(newTypeParameter,
        DecoratedTypeParameterBounds.current.get(oldTypeParameter));
  }

  @override
  bool getConditionalKnownValue(AstNode node) =>
      _wrapExceptions(node, () => null, () {
        // TODO(paulberry): handle conditional expressions.
        var conditionalDiscard = _fixBuilder._variables
            .getConditionalDiscard(_fixBuilder.source, node);
        if (conditionalDiscard == null) {
          return null;
        } else {
          if (conditionalDiscard.keepTrue && conditionalDiscard.keepFalse) {
            return null;
          }
          var conditionValue = conditionalDiscard.keepTrue;
          (_fixBuilder._getChange(node) as NodeChangeForConditional)
            ..conditionValue = conditionValue
            ..conditionReasons = conditionalDiscard.reasons.toList();
          return conditionValue;
        }
      });

  @override
  List<ParameterElement> getExecutableParameters(ExecutableElement element) =>
      getExecutableType(element as ElementImplWithFunctionType).parameters;

  @override
  DartType getExecutableReturnType(Element element) =>
      getExecutableType(element as ElementImplWithFunctionType).returnType;

  @override
  FunctionType getExecutableType(ElementImplWithFunctionType element) =>
      _wrapExceptions(_fixBuilder.unit, () => element.typeInternal, () {
        var type = _fixBuilder._computeMigratedType(element);
        Element baseElement = element;
        if (baseElement is Member) {
          type = baseElement.substitution.substituteType(type);
        }
        return type as FunctionType;
      });

  @override
  DartType getFieldType(PropertyInducingElementImpl element) =>
      _wrapExceptions(_fixBuilder.unit, () => element.typeInternal, () {
        assert(!element.isSynthetic);
        return _fixBuilder._computeMigratedType(element);
      });

  @override
  List<CollectionElement> getListElements(ListLiteral node) => _wrapExceptions(
      node,
      () => node.elements,
      () => _collectionElements[node] ??=
          _transformCollectionElements(node.elements, node.typeArguments));

  @override
  List<CollectionElement> getSetOrMapElements(SetOrMapLiteral node) =>
      _wrapExceptions(
          node,
          () => node.elements,
          () => _collectionElements[node] ??=
              _transformCollectionElements(node.elements, node.typeArguments));

  @override
  DartType getTypeParameterBound(TypeParameterElementImpl element) {
    var decoratedBound = _fixBuilder._variables
        .decoratedTypeParameterBound(element, allowNullUnparentedBounds: true);
    if (decoratedBound == null) return element.boundInternal;
    var bound = _fixBuilder._variables.toFinalType(decoratedBound);
    if (bound.isDynamic) {
      return null;
    } else if (bound.isDartCoreObject &&
        bound.nullabilitySuffix == NullabilitySuffix.question) {
      return null;
    } else {
      return bound;
    }
  }

  @override
  DartType getVariableType(VariableElementImpl variable) =>
      _wrapExceptions(_fixBuilder.unit, () => variable.typeInternal, () {
        if (variable.library == null) {
          // This is a synthetic variable created during resolution (e.g. a
          // parameter of a function type), so the type it currently has is the
          // correct post-migration type.
          return variable.typeInternal;
        }
        return _fixBuilder._computeMigratedType(variable);
      });

  @override
  bool isIndexExpressionNullAware(IndexExpression node) {
    // Null-aware index expressions weren't supported prior to NNBD.
    assert(!node.isNullAware);
    return false;
  }

  @override
  bool isMethodInvocationNullAware(MethodInvocation node) {
    return node.isNullAware &&
        (_shouldStayNullAware[node] ??= _fixBuilder._shouldStayNullAware(node));
  }

  @override
  bool isPropertyAccessNullAware(PropertyAccess node) {
    return node.isNullAware &&
        (_shouldStayNullAware[node] ??= _fixBuilder._shouldStayNullAware(node));
  }

  @override
  DartType modifyExpressionType(Expression node, DartType type) =>
      _wrapExceptions(node, () => type, () {
        if (_fixBuilder._variables.hasNullCheckHint(_fixBuilder.source, node)) {
          type = _addNullCheck(node, type,
              info: AtomicEditInfo(NullabilityFixDescription.checkExpression,
                  [FixReason_NullCheckHint(CodeReference.fromAstNode(node))]));
        }
        if (type.isDynamic) return type;
        var ancestor = _findNullabilityContextAncestor(node);
        var context =
            InferenceContext.getContext(ancestor) ?? DynamicTypeImpl.instance;
        if (!_fixBuilder._typeSystem.isSubtypeOf(type, context)) {
          // Either a cast or a null check is needed.  We prefer to do a null
          // check if we can.
          var nonNullType = _fixBuilder._typeSystem.promoteToNonNull(type);
          if (_fixBuilder._typeSystem.isSubtypeOf(nonNullType, context)) {
            return _addNullCheck(node, type);
          } else {
            return _addCast(node, context);
          }
        }
        if (!_fixBuilder._typeSystem.isNullable(type)) return type;
        if (_needsNullCheckDueToStructure(ancestor)) {
          return _addNullCheck(node, type);
        }
        return type;
      });

  @override
  DartType modifyInferredParameterType(
      ParameterElement parameter, DartType type) {
    var postMigrationType = parameter.type;
    if (postMigrationType != type) {
      // TODO(paulberry): make sure we test all kinds of parameters
      _fixBuilder._addedParameterTypes[parameter] = postMigrationType;
      return postMigrationType;
    }
    return type;
  }

  @override
  void setFlowAnalysis(
      FlowAnalysis<AstNode, Statement, Expression, PromotableElement, DartType>
          flowAnalysis) {
    _flowAnalysis = flowAnalysis;
  }

  DartType _addCast(Expression node, DartType contextType) {
    var checks =
        _fixBuilder._variables.expressionChecks(_fixBuilder.source, node);
    var info = checks != null
        ? AtomicEditInfo(
            NullabilityFixDescription.checkExpression, checks.edges)
        : null;
    (_fixBuilder._getChange(node) as NodeChangeForExpression)
        .introduceAs(contextType, info);
    _flowAnalysis.asExpression_end(node, contextType);
    return contextType;
  }

  DartType _addNullCheck(Expression node, DartType type,
      {AtomicEditInfo info}) {
    var checks =
        _fixBuilder._variables.expressionChecks(_fixBuilder.source, node);
    info ??= checks != null
        ? AtomicEditInfo(
            NullabilityFixDescription.checkExpression, checks.edges)
        : null;
    (_fixBuilder._getChange(node) as NodeChangeForExpression)
        .addNullCheck(info);
    _flowAnalysis.nonNullAssert_end(node);
    return _fixBuilder._typeSystem.promoteToNonNull(type as TypeImpl);
  }

  Expression _findNullabilityContextAncestor(Expression node) {
    while (true) {
      var parent = node.parent;
      if (parent is BinaryExpression &&
          parent.operator.type == TokenType.QUESTION_QUESTION &&
          identical(node, parent.rightOperand)) {
        node = parent;
        continue;
      }
      return node;
    }
  }

  bool _needsNullCheckDueToStructure(Expression node) {
    var parent = node.parent;
    if (parent is BinaryExpression) {
      if (identical(node, parent.leftOperand)) {
        var operatorType = parent.operator.type;
        if (operatorType == TokenType.QUESTION_QUESTION ||
            operatorType == TokenType.EQ_EQ ||
            operatorType == TokenType.BANG_EQ) {
          return false;
        } else {
          return true;
        }
      }
    } else if (parent is PrefixedIdentifier) {
      // TODO(paulberry): ok for toString etc. if the shape is correct
      return identical(node, parent.prefix);
    } else if (parent is PropertyAccess) {
      // TODO(paulberry): what about cascaded?
      // TODO(paulberry): ok for toString etc. if the shape is correct
      return parent.operator.type == TokenType.PERIOD &&
          identical(node, parent.target);
    } else if (parent is MethodInvocation) {
      // TODO(paulberry): what about cascaded?
      // TODO(paulberry): ok for toString etc. if the shape is correct
      return parent.operator.type == TokenType.PERIOD &&
          identical(node, parent.target);
    } else if (parent is IndexExpression) {
      return identical(node, parent.target);
    } else if (parent is ConditionalExpression) {
      return identical(node, parent.condition);
    } else if (parent is FunctionExpressionInvocation) {
      return identical(node, parent.function);
    } else if (parent is PrefixExpression) {
      // TODO(paulberry): for prefix increment/decrement, inserting a null check
      // isn't sufficient.
      return true;
    } else if (parent is ThrowExpression) {
      return true;
    }
    return false;
  }

  CollectionElement _transformCollectionElement(CollectionElement node) {
    while (node is IfElement) {
      var conditionalDiscard = _fixBuilder._variables
          .getConditionalDiscard(_fixBuilder.source, node);
      if (conditionalDiscard == null ||
          conditionalDiscard.keepTrue && conditionalDiscard.keepFalse) {
        return node;
      }
      var conditionValue = conditionalDiscard.keepTrue;
      var ifElement = node as IfElement;
      node = conditionValue ? ifElement.thenElement : ifElement.elseElement;
    }
    return node;
  }

  List<CollectionElement> _transformCollectionElements(
      NodeList<CollectionElement> elements, TypeArgumentList typeArguments) {
    return elements
        .map(_transformCollectionElement)
        .where((e) => e != null)
        .toList();
  }

  /// Runs the computation in [compute].  If an exception occurs and
  /// [_fixBuilder.listener] is non-null, the exception is reported to the
  /// listener and [fallback] is called to produce a result.  Otherwise the
  /// exception is propagated normally.
  T _wrapExceptions<T>(
      AstNode node, T Function() fallback, T Function() compute) {
    if (_fixBuilder.listener == null) return compute();
    try {
      return compute();
    } catch (exception, stackTrace) {
      _fixBuilder.listener
          .reportException(_fixBuilder.source, node, exception, stackTrace);
      return fallback();
    }
  }
}

/// Problem reported by [FixBuilder] when encountering a non-nullable unnamed
/// optional parameter that lacks a default value.
class NonNullableUnnamedOptionalParameter implements Problem {
  const NonNullableUnnamedOptionalParameter();
}

/// Common supertype for problems reported by [FixBuilder._addProblem].
abstract class Problem {}

/// Visitor that computes additional migrations on behalf of [FixBuilder] that
/// should be run after resolution
class _FixBuilderPostVisitor extends GeneralizingAstVisitor<void>
    with PermissiveModeVisitor<void> {
  final FixBuilder _fixBuilder;

  _FixBuilderPostVisitor(this._fixBuilder);

  @override
  NullabilityMigrationListener get listener => _fixBuilder.listener;

  @override
  Source get source => _fixBuilder.source;

  @override
  void visitAsExpression(AsExpression node) {
    if (!_fixBuilder._variables.wasUnnecessaryCast(_fixBuilder.source, node) &&
        BestPracticesVerifier.isUnnecessaryCast(
            node, _fixBuilder._typeSystem)) {
      (_fixBuilder._getChange(node) as NodeChangeForAsExpression).removeAs =
          true;
    }
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    if ((node as CompilationUnitImpl).languageVersionToken != null) {
      (_fixBuilder._getChange(node) as NodeChangeForCompilationUnit)
          .removeLanguageVersionComment = true;
    }
    super.visitCompilationUnit(node);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    if (node.type == null) {
      var typeToAdd = _fixBuilder._addedParameterTypes[node.declaredElement];
      if (typeToAdd != null) {
        (_fixBuilder._getChange(node) as NodeChangeForSimpleFormalParameter)
            .addExplicitType = typeToAdd;
      }
    }
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    if (node.type == null) {
      // TODO(paulberry): for fields, handle inference via override as well.
      List<DartType> neededTypes = [];
      List<DartType> inferredTypes = [];
      bool explicitTypeNeeded = false;
      for (var variableDeclaration in node.variables) {
        var neededType = _fixBuilder
            ._computeMigratedType(variableDeclaration.declaredElement);
        neededTypes.add(neededType);
        var inferredType = variableDeclaration.initializer?.staticType ??
            _fixBuilder.typeProvider.dynamicType;
        inferredTypes.add(inferredType);
        if (neededType != inferredType) {
          explicitTypeNeeded = true;
        }
      }
      if (explicitTypeNeeded) {
        var firstNeededType = neededTypes[0];
        if (neededTypes.any((t) => t != firstNeededType)) {
          throw UnimplementedError(
              'Different explicit types needed in multi-variable declaration');
        } else {
          (_fixBuilder._getChange(node) as NodeChangeForVariableDeclarationList)
              .addExplicitType = firstNeededType;
        }
      }
    }
    if (_fixBuilder._variables.isLateHinted(source, node)) {
      (_fixBuilder._getChange(node) as NodeChangeForVariableDeclarationList)
          .addLate = true;
    }
    super.visitVariableDeclarationList(node);
  }
}

/// Visitor that computes additional migrations on behalf of [FixBuilder] that
/// don't need to be integrated into the resolver itself, and should be run
/// prior to resolution
class _FixBuilderPreVisitor extends GeneralizingAstVisitor<void>
    with PermissiveModeVisitor<void> {
  final FixBuilder _fixBuilder;

  _FixBuilderPreVisitor(this._fixBuilder);

  @override
  NullabilityMigrationListener get listener => _fixBuilder.listener;

  @override
  Source get source => _fixBuilder.source;

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    var element = node.declaredElement;
    if (node.defaultValue == null) {
      var nullabilityNode =
          _fixBuilder._variables.decoratedElementType(element).node;
      if (!nullabilityNode.isNullable) {
        if (element.isNamed) {
          _addRequiredKeyword(node, nullabilityNode);
        } else {
          _fixBuilder._addProblem(
              node, const NonNullableUnnamedOptionalParameter());
        }
      } else if (element.metadata.any((m) => m.isRequired)) {
        _addRequiredKeyword(node, nullabilityNode);
      }
    }
    super.visitDefaultFormalParameter(node);
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    var decoratedType = _fixBuilder._variables
        .decoratedTypeAnnotation(_fixBuilder.source, node);
    if (!typeIsNonNullableByContext(node)) {
      (_fixBuilder._getChange(node) as NodeChangeForTypeAnnotation)
        ..makeNullable = decoratedType.node.isNullable
        ..decoratedType = decoratedType;
    }
    (node as GenericFunctionTypeImpl).type =
        _fixBuilder._variables.toFinalType(decoratedType);
    super.visitGenericFunctionType(node);
  }

  @override
  void visitTypeName(TypeName node) {
    var decoratedType = _fixBuilder._variables
        .decoratedTypeAnnotation(_fixBuilder.source, node);
    if (!typeIsNonNullableByContext(node)) {
      var type = decoratedType.type;
      if (!type.isDynamic && !type.isVoid) {
        (_fixBuilder._getChange(node) as NodeChangeForTypeAnnotation)
          ..makeNullable = decoratedType.node.isNullable
          ..decoratedType = decoratedType;
      }
    }
    node.type = _fixBuilder._variables.toFinalType(decoratedType);
    super.visitTypeName(node);
  }

  void _addRequiredKeyword(
      DefaultFormalParameter parameter, NullabilityNode node) {
    // Change an existing `@required` annotation into a `required` keyword if
    // possible.
    final element = parameter.declaredElement;
    final method = element.enclosingElement;
    final cls = method.enclosingElement;
    var info = AtomicEditInfo(
        NullabilityFixDescription.addRequired(
            cls.name, method.name, element.name),
        [node]);
    var metadata = parameter.metadata;
    for (var annotation in metadata) {
      if (annotation.elementAnnotation.isRequired) {
        // TODO(paulberry): what if `@required` isn't the first annotation?
        // Will we produce something that isn't grammatical?
        (_fixBuilder._getChange(annotation) as NodeChangeForAnnotation)
          ..changeToRequiredKeyword = true
          ..changeToRequiredKeywordInfo = info;
        return;
      }
    }
    // Otherwise create a new `required` keyword.
    (_fixBuilder._getChange(parameter) as NodeChangeForDefaultFormalParameter)
      ..addRequiredKeyword = true
      ..addRequiredKeywordInfo = info;
  }
}
