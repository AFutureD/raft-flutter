import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

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
