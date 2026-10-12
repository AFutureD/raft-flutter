import 'package:dio/dio.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;

/// Platforms without dart:io (web) use the browser's networking and proxy.
Dio createProxiedDio(BaseOptions? options) => Dio(options);

sio.OptionBuilder applyProxyTransport(sio.OptionBuilder builder) => builder;
