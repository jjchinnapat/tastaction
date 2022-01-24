// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../logging.dart';
import '../protocol_stream.dart';
import '../stream_transformers.dart';
import 'dart.dart';
import 'mixins.dart';

/// A DAP Debug Adapter for running and debugging Dart test scripts.
class DartTestDebugAdapter extends DartDebugAdapter<DartLaunchRequestArguments,
        DartAttachRequestArguments>
    with PidTracker, VmServiceInfoFileUtils, PackageConfigUtils, TestAdapter {
  Process? _process;

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;

  @override
  final parseAttachArgs = DartAttachRequestArguments.fromJson;

  DartTestDebugAdapter(
    ByteStreamServerChannel channel, {
    bool ipv6 = false,
    bool enableDds = true,
    bool enableAuthCodes = true,
    Logger? logger,
  }) : super(
          channel,
          ipv6: ipv6,
          enableDds: enableDds,
          enableAuthCodes: enableAuthCodes,
          logger: logger,
        );

  /// Whether the VM Service closing should be used as a signal to terminate the
  /// debug session.
  ///
  /// Since we do not support attaching for tests, this is always false.
  bool get terminateOnVmServiceClose => false;

  Future<void> debuggerConnected(vm.VM vmInfo) async {
    // Capture the PID from the VM Service so that we can terminate it when
    // cleaning up. Terminating the process might not be enough as it could be
    // just a shell script (e.g. pub on Windows) and may not pass the
    // signal on correctly.
    // See: https://github.com/Dart-Code/Dart-Code/issues/907
    final pid = vmInfo.pid;
    if (pid != null) {
      pidsToTerminate.add(pid);
    }
  }

  /// Called by [disconnectRequest] to request that we forcefully shut down the
  /// app being run (or in the case of an attach, disconnect).
  Future<void> disconnectImpl() async {
    terminatePids(ProcessSignal.sigkill);
  }

  /// Called by [launchRequest] to request that we actually start the app to be
  /// run/debugged.
  ///
  /// For debugging, this should start paused, connect to the VM Service, set
  /// breakpoints, and resume.
  Future<void> launchImpl() async {
    final args = this.args as DartLaunchRequestArguments;
    final vmPath = Platform.resolvedExecutable;
    File? vmServiceInfoFile;

    final debug = !(args.noDebug ?? false);
    if (debug) {
      vmServiceInfoFile = generateVmServiceInfoFile();
      unawaited(waitForVmServiceInfoFile(logger, vmServiceInfoFile)
          .then((uri) => connectDebugger(uri, resumeIfStarting: true)));
    }

    final vmArgs = <String>[
      if (debug) ...[
        '--enable-vm-service=${args.vmServicePort ?? 0}${ipv6 ? '/::1' : ''}',
        '--pause_isolates_on_start',
        if (!enableAuthCodes) '--disable-service-auth-codes'
      ],
      if (debug && vmServiceInfoFile != null) ...[
        '-DSILENT_OBSERVATORY=true',
        '--write-service-info=${Uri.file(vmServiceInfoFile.path)}'
      ],
      // Default to asserts on, this seems like the most useful behaviour for
      // editor-spawned debug sessions.
      if (args.enableAsserts ?? true) '--enable-asserts',
      // TODO(dantup): This should be changed from "dart run test:test" to
      // "dart test" once the started-paused flags are working correctly.
      // Currently they start paused but do not write the vm-service-info file
      // to give us the VM-service URI.
      // https://github.com/dart-lang/sdk/issues/44200#issuecomment-726869539
      // We should also ensure DDS is disabled (this may need a new flag since
      // we can't disable-dart-dev to get "dart test") and devtools is not
      // served.
      // '--disable-dart-dev',
      'run',
      '--no-serve-devtools',
      'test:test',
      '-r',
      'json',
    ];
    final processArgs = [
      ...vmArgs,
      ...?args.toolArgs,
      args.program,
      ...?args.args,
    ];

    // Find the package_config file for this script.
    // TODO(dantup): Remove this once
    //   https://github.com/dart-lang/sdk/issues/45530 is done as it will not be
    //   necessary.
    var possibleRoot = path.isAbsolute(args.program)
        ? path.dirname(args.program)
        : path.dirname(path.normalize(path.join(args.cwd ?? '', args.program)));
    final packageConfig = findPackageConfigFile(possibleRoot);
    if (packageConfig != null) {
      this.usePackageConfigFile(packageConfig);
    }

    // TODO(dantup): Support passing env to both of these.

    logger?.call('Spawning $vmPath with $processArgs in ${args.cwd}');
    final process = await Process.start(
      vmPath,
      processArgs,
      workingDirectory: args.cwd,
    );
    _process = process;
    pidsToTerminate.add(process.pid);

    process.stdout.transform(ByteToLineTransformer()).listen(_handleStdout);
    process.stderr.listen(_handleStderr);
    unawaited(process.exitCode.then(_handleExitCode));
  }

  /// Called by [attachRequest] to request that we actually connect to the app
  /// to be debugged.
  Future<void> attachImpl() async {
    sendOutput('console', '\nAttach is not supported for test runs');
    handleSessionTerminate();
  }

  /// Called by [terminateRequest] to request that we gracefully shut down the
  /// app being run (or in the case of an attach, disconnect).
  Future<void> terminateImpl() async {
    terminatePids(ProcessSignal.sigterm);
    await _process?.exitCode;
  }

  void _handleExitCode(int code) {
    final codeSuffix = code == 0 ? '' : ' ($code)';
    logger?.call('Process exited ($code)');
    handleSessionTerminate(codeSuffix);
  }

  void _handleStderr(List<int> data) {
    sendOutput('stderr', utf8.decode(data));
  }

  void _handleStdout(String data) {
    // Output to stdout is expected to be JSON from the test runner. If we
    // get non-JSON output we will just pass it through to the front-end so it
    // shows up in the client and can be seen (although we generally expect
    // package:test to have captured output and sent it in "print" events).
    try {
      final payload = jsonDecode(data);
      sendTestEvents(payload);
    } catch (e) {
      sendOutput('stdout', data);
    }
  }
}
