import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'checks.dart';

/// A reference to an API: a class (`member == null`), or a member of a class.
/// [library] is a URI prefix such as `package:flutter/` or `dart:io`; [owner]
/// is the declaring class name (null for a top-level function); [member] is the
/// constructor name (`''` for the unnamed one), method or field name, null for
/// "the class itself and every constructor".
class ApiRef {
  const ApiRef(this.library, this.owner, [this.member]);
  final String library;
  final String? owner;
  final String? member;

  bool matches(Element element) {
    var lib = element.library?.uri.toString();
    // dart:io re-exports its HTTP and WebSocket classes from dart:_http.
    if (lib == 'dart:_http') lib = 'dart:io';
    if (lib == null || !lib.startsWith(library)) return false;
    switch (element) {
      case ConstructorElement():
        if (owner == null || element.enclosingElement.name != owner) {
          return false;
        }
        return member == null || (element.name ?? '') == member;
      case InterfaceElement():
        return owner == element.name && member == null;
      case ExecutableElement():
        final enclosing = element.enclosingElement;
        final enclosingName = enclosing is InterfaceElement
            ? enclosing.name
            : null;
        return enclosingName == owner && element.name == member;
      case PropertyInducingElement():
        final enclosing = element.enclosingElement;
        return enclosing is InterfaceElement &&
            enclosing.name == owner &&
            element.name == member;
      default:
        return false;
    }
  }
}

/// One banned-API rule: a name, a message and the references it forbids.
/// Constructors are matched where they are called; [typeReferences] also bans
/// the class as a type name (`Slider x`, `extends Slider`).
class BannedApi {
  const BannedApi({
    required this.rule,
    required this.message,
    required this.correction,
    required this.refs,
    this.typeReferences = false,
    this.namedArguments = const [],
  });
  final String rule;
  final String message;
  final String correction;
  final List<ApiRef> refs;
  final bool typeReferences;

  /// Named-argument labels that are banned outright (`backgroundImage:`).
  final List<String> namedArguments;

  bool matches(Element? element) =>
      element != null && refs.any((r) => r.matches(element));
}

const proxyRule = 'avoid_unproxied_network_client';
const imageRule = 'avoid_raw_image_decode';
const underlineRule = 'avoid_builtin_underline';
const sliderRule = 'avoid_material_slider';
const feedbackRule = 'avoid_material_feedback';

String _ignore(String rule) =>
    "add '// ignore: raft_lints/$rule -- <why this site is exempt>'";

final bannedApis = <BannedApi>[
  BannedApi(
    rule: proxyRule,
    message:
        'Creates a network client of its own instead of following the shared '
        'proxy decision (system / manual / direct).',
    correction:
        'Build it with createProxiedDio / SystemProxy.createHttpClient / '
        'proxiedWebSocketConnector (docs/system-proxy.md), or '
        '${_ignore(proxyRule)}.',
    refs: const [
      ApiRef('dart:io', 'HttpClient'),
      ApiRef('dart:io', 'HttpClient', 'findProxyFromEnvironment'),
      ApiRef('dart:io', 'WebSocket', 'connect'),
      ApiRef('package:dio/', 'Dio'),
      ApiRef('package:dio/', 'IOHttpClientAdapter'),
      ApiRef('package:http/', 'IOClient'),
      ApiRef('package:http/', 'Client'),
      ApiRef('package:socket_io_client/', null, 'io'),
    ],
  ),
  BannedApi(
    rule: imageRule,
    message:
        'Raw image provider or Image widget keeps the whole source bitmap in '
        'the shared ImageCache.',
    correction:
        'Use RaftSizedImage / raftSizedImage so the decode size is the '
        'display size, or ${_ignore(imageRule)}.',
    namedArguments: const ['backgroundImage'],
    refs: const [
      ApiRef('package:flutter/', 'NetworkImage'),
      ApiRef('package:flutter/', 'MemoryImage'),
      ApiRef('package:flutter/', 'FileImage'),
      ApiRef('package:flutter/', 'AssetImage'),
      ApiRef('package:flutter/', 'ExactAssetImage'),
      ApiRef('package:flutter/', 'DecorationImage'),
      ApiRef('package:flutter/', 'Image'),
      ApiRef('package:flutter/', 'RawImage'),
      ApiRef('package:cached_network_image/', 'CachedNetworkImage'),
      ApiRef('package:cross_cache/', 'CachedNetworkImage'),
      ApiRef('dart:ui', 'ImageDescriptor'),
      ApiRef('dart:ui', null, 'instantiateImageCodec'),
      ApiRef('package:flutter/', null, 'instantiateImageCodec'),
    ],
  ),
  BannedApi(
    rule: underlineRule,
    message:
        "Flutter's TextDecoration.underline hugs the glyphs and cannot be "
        'offset, so it differs from the hyperlink underline.',
    correction:
        'Use RaftUnderlinedText / RaftUnderlineSpan + RaftUnderlines '
        '(raft_underline.dart), or ${_ignore(underlineRule)}.',
    refs: const [ApiRef('package:flutter/', 'TextDecoration', 'underline')],
  ),
  BannedApi(
    rule: feedbackRule,
    message:
        'Material SnackBar / ScaffoldMessenger / MaterialBanner for feedback '
        'instead of the raft_ui toast and banner.',
    correction:
        'Use showRaftToast / RaftErrorBanner (error_presentation.dart), or '
        '${_ignore(feedbackRule)}.',
    typeReferences: true,
    refs: const [
      ApiRef('package:flutter/', 'SnackBar'),
      ApiRef('package:flutter/', 'MaterialBanner'),
      ApiRef('package:flutter/', 'ScaffoldMessenger'),
      ApiRef('package:flutter/', 'ScaffoldMessenger', 'of'),
      ApiRef('package:flutter/', 'ScaffoldMessenger', 'maybeOf'),
      ApiRef('package:flutter/', 'ScaffoldMessengerState'),
      ApiRef('package:flutter/', 'ScaffoldMessengerState', 'showSnackBar'),
      ApiRef(
        'package:flutter/',
        'ScaffoldMessengerState',
        'showMaterialBanner',
      ),
    ],
  ),
  BannedApi(
    rule: sliderRule,
    message:
        'The Material slider (yellow thumb, tick marks, its own semantics) '
        'must not come back in media UI.',
    correction:
        'Draw the rail with the shared video controls, or '
        '${_ignore(sliderRule)}.',
    typeReferences: true,
    refs: const [
      ApiRef('package:flutter/', 'Slider'),
      ApiRef('package:flutter/', 'RangeSlider'),
      ApiRef('package:flutter/', 'CupertinoSlider'),
      ApiRef('package:flutter/', 'SliderTheme'),
      ApiRef('package:flutter/', 'SliderThemeData'),
    ],
  ),
];

/// Runs the banned-API checks on one node. [element] is what the node
/// resolves to (a constructor for a creation, the method for an invocation, the
/// accessed member for a property access, the class for a type name).
void checkBannedApi(AstNode node, Element? element, Report report) {
  for (final api in bannedApis) {
    // A type-name ban already reports the creation's type name.
    if (api.typeReferences && node is InstanceCreationExpression) continue;
    if (api.matches(element)) report(api.rule, node);
  }
}

/// `backgroundImage: ...` style named arguments.
void checkBannedNamedArgument(NamedArgument node, Report report) {
  for (final api in bannedApis) {
    if (api.namedArguments.contains(node.name.lexeme)) report(api.rule, node);
  }
}

/// Class type names (`Slider x`): only for APIs that ask for it.
void checkBannedTypeName(NamedType node, Report report) {
  final element = node.element;
  for (final api in bannedApis) {
    if (api.typeReferences && api.matches(element)) report(api.rule, node);
  }
}
