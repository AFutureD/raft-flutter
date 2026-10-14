// The phone shell mounts every page on a `_MobilePageController`, a borrowed
// WorkspaceController that mirrors its source: the host copies the source's
// state in `synchronizePagePresentation` and hands the source's collaborators
// to the constructor. A member added to WorkspaceController but missed in
// either place is silent on desktop and wrong on phone only (`planRevision`
// was never copied, so phone Plan & Billing never reloaded).
//
// These tests parse the sources (syntax only) and make every such member an
// explicit decision: copied/forwarded, or listed below with the reason it
// needs no copy.
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Public mutable members of WorkspaceController that
/// `synchronizePagePresentation` does not copy, and why that is correct.
const _notCopied = <String, String>{
  'mobileNavigation':
      'per-controller flag; _MobilePageController passes true to the '
      'constructor',
  'section':
      'derived from `navigation`, which _MobilePageNavigation projects from '
      'the source (projectHistory)',
  'threadSummaries':
      'the setter writes _summariesByChannel, which delegates to '
      'presentationSource',
  'pendingMentionActions':
      'delegated to source: reads and dismissals go through presentationSource',
  'sendWarnings':
      'delegated to source: reads and dismissals go through presentationSource',
};

/// WorkspaceController constructor parameters `_MobilePageController` does not
/// forward to `super`, and why that is correct.
const _notForwarded = <String, String>{
  'attachmentUrls':
      'delegated to source: attachmentUrl() forwards to presentationSource '
      'before touching the cache, and sharing the instance would let the '
      "page's dispose() dispose the source's cache",
};

class _Touched extends RecursiveAstVisitor<void> {
  /// Names assigned (`x = ...`, `this.x = ...`) or mutated in place
  /// (`x.addAll(...)`, `x..clear()`).
  final names = <String>{};

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    if (left is SimpleIdentifier) names.add(left.name);
    if (left is PropertyAccess && left.target is ThisExpression) {
      names.add(left.propertyName.name);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (target is SimpleIdentifier) names.add(target.name);
    super.visitMethodInvocation(node);
  }

  @override
  void visitCascadeExpression(CascadeExpression node) {
    final target = node.target;
    if (target is SimpleIdentifier) names.add(target.name);
    super.visitCascadeExpression(node);
  }
}

ClassDeclaration _class(String path, String name) {
  final unit = parseString(content: File(path).readAsStringSync()).unit;
  return unit.declarations.whereType<ClassDeclaration>().firstWhere(
    (c) => c.namePart.typeName.lexeme == name,
    orElse: () => fail('$name not found in $path'),
  );
}

List<ClassMember> _members(ClassDeclaration c) =>
    (c.body as BlockClassBody).members.toList();

const _controller = 'lib/data/workspace_controller.dart';
const _route = 'lib/features/mobile_workspace_route.dart';

/// Public members that hold state a page could read: reassignable fields,
/// setters, and final collections (their contents are mutable).
Set<String> _stateMembers(ClassDeclaration c) {
  final names = <String>{};
  for (final m in _members(c)) {
    if (m is FieldDeclaration && !m.isStatic) {
      final list = m.fields;
      final type = list.type?.toSource() ?? '';
      final collection =
          type.startsWith('Map<') ||
          type.startsWith('List<') ||
          type.startsWith('Set<');
      if (list.isConst || (list.isFinal && !collection)) continue;
      for (final v in list.variables) {
        if (!v.name.lexeme.startsWith('_')) names.add(v.name.lexeme);
      }
    } else if (m is MethodDeclaration &&
        m.isSetter &&
        !m.isStatic &&
        !m.name.lexeme.startsWith('_')) {
      names.add(m.name.lexeme);
    }
  }
  return names;
}

void main() {
  test('every public mutable WorkspaceController field is copied into the '
      'phone page mirror or listed with a reason', () {
    final c = _class(_controller, 'WorkspaceController');
    final sync = _members(c)
        .whereType<MethodDeclaration>()
        .firstWhere((m) => m.name.lexeme == 'synchronizePagePresentation');
    final touched = (_Touched()..visitMethodDeclaration(sync)).names;
    final state = _stateMembers(c);
    expect(
      state,
      containsAll(['planRevision', 'servers', 'loading']),
      reason: 'the scan itself found no fields; the parser is out of date',
    );

    final missing = state
        .difference(touched)
        .difference(_notCopied.keys.toSet());
    expect(
      missing,
      isEmpty,
      reason:
          'copy these in WorkspaceController.synchronizePagePresentation '
          '(source -> phone page) or add them to _notCopied with the reason '
          'they need no copy',
    );
    expect(
      _notCopied.keys.where((k) => !state.contains(k) || touched.contains(k)),
      isEmpty,
      reason: '_notCopied has an entry that is gone or is copied after all',
    );
    expect(_notCopied.values.where((r) => r.trim().isEmpty), isEmpty);
  });

  test('every WorkspaceController constructor parameter is forwarded by '
      '_MobilePageController or listed with a reason', () {
    final params = <String, bool>{}; // name -> positional
    for (final m in _members(_class(_controller, 'WorkspaceController'))) {
      if (m is! ConstructorDeclaration || m.name != null) continue;
      for (var p in m.parameters.parameters) {
        final positional = p.isPositional && !p.isOptionalPositional;
        if (p is DefaultFormalParameter) p = p.parameter;
        params[p.name!.lexeme] = positional;
      }
    }
    expect(params, containsPair('presentationSource', false));

    final page = _members(_class(_route, '_MobilePageController'));
    final ctor = page.whereType<ConstructorDeclaration>().single;
    final call = ctor.initializers
        .whereType<SuperConstructorInvocation>()
        .single
        .argumentList
        .arguments;
    final forwarded = <String>{
      for (final a in call.whereType<NamedExpression>()) a.name.label.name,
    };
    final positionalNames = [
      for (final e in params.entries)
        if (e.value) e.key,
    ];
    final positionalCount = call.where((a) => a is! NamedExpression).length;
    forwarded.addAll(positionalNames.take(positionalCount));

    final missing = params.keys
        .toSet()
        .difference(forwarded)
        .difference(_notForwarded.keys.toSet());
    expect(
      missing,
      isEmpty,
      reason:
          'pass these from the source in _MobilePageController (super(...)) '
          'or add them to _notForwarded with the reason they are not',
    );
    expect(
      _notForwarded.keys.where(
        (k) => !params.containsKey(k) || forwarded.contains(k),
      ),
      isEmpty,
      reason: '_notForwarded has an entry that is gone or is forwarded now',
    );
    expect(_notForwarded.values.where((r) => r.trim().isEmpty), isEmpty);
  });
}
