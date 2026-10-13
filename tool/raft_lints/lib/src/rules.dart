import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import 'banned_apis.dart';
import 'checks.dart';

/// `expr[key]!` in render code.
class AvoidRenderIndexAssertion extends AnalysisRule {
  AvoidRenderIndexAssertion()
    : super(
        name: indexAssertionRule,
        description:
            'No map-index null assertion (`m[k]!`) in widget-returning '
            'functions and builder closures.',
      );

  static const LintCode code = LintCode(
    indexAssertionRule,
    indexAssertionMessage,
    correctionMessage: indexAssertionCorrection,
  );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    registry.addPostfixExpression(this, _Visitor(this));
  }
}

/// `.single` in render code.
class AvoidRenderSingle extends AnalysisRule {
  AvoidRenderSingle()
    : super(
        name: singleRule,
        description:
            'No `.single` in widget-returning functions and builder closures.',
      );

  static const LintCode code = LintCode(
    singleRule,
    singleMessage,
    correctionMessage: singleCorrection,
  );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    final visitor = _Visitor(this);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addPropertyAccess(this, visitor);
  }
}

/// `firstWhere` / `lastWhere` / `singleWhere` without `orElse` in render code.
class AvoidRenderWhereWithoutOrElse extends AnalysisRule {
  AvoidRenderWhereWithoutOrElse()
    : super(
        name: whereRule,
        description:
            'No `firstWhere`/`lastWhere`/`singleWhere` without `orElse` in '
            'widget-returning functions and builder closures.',
      );

  static const LintCode code = LintCode(
    whereRule,
    whereMessage,
    correctionMessage: whereCorrection,
  );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    registry.addMethodInvocation(this, _Visitor(this));
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);
  final AnalysisRule rule;

  void _report(String _, AstNode node) => rule.reportAtNode(node);

  @override
  void visitPostfixExpression(PostfixExpression node) =>
      checkIndexAssertion(node, _report);

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) =>
      checkSingle(node, node.identifier, _report);

  @override
  void visitPropertyAccess(PropertyAccess node) =>
      checkSingle(node, node.propertyName, _report);

  @override
  void visitMethodInvocation(MethodInvocation node) =>
      checkWhere(node, _report);
}

/// A banned-API rule built from a [BannedApi] spec.
class BannedApiRule extends AnalysisRule {
  BannedApiRule(this.api)
    : code = LintCode(api.rule, api.message, correctionMessage: api.correction),
      super(name: api.rule, description: api.message);

  final BannedApi api;
  final LintCode code;

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    final visitor = _BannedVisitor(this, api);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addPropertyAccess(this, visitor);
    if (api.typeReferences) registry.addNamedType(this, visitor);
    if (api.namedArguments.isNotEmpty) {
      registry.addNamedArgument(this, visitor);
    }
  }
}

class _BannedVisitor extends SimpleAstVisitor<void> {
  _BannedVisitor(this.rule, this.api);
  final AnalysisRule rule;
  final BannedApi api;

  void _report(String _, AstNode node) => rule.reportAtNode(node);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (api.typeReferences) return; // reported via the type name
    if (api.matches(node.constructorName.element)) _report(api.rule, node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (api.matches(node.methodName.element)) {
      _report(api.rule, node.methodName);
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (api.matches(node.identifier.element)) _report(api.rule, node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (api.matches(node.propertyName.element)) _report(api.rule, node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (api.matches(node.element)) _report(api.rule, node);
  }

  @override
  void visitNamedArgument(NamedArgument node) {
    if (api.namedArguments.contains(node.name.lexeme)) {
      _report(api.rule, node);
    }
  }
}
