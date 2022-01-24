// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart' as vm;

import '../../../dds.dart';
import '../base_debug_adapter.dart';
import '../exceptions.dart';
import '../isolate_manager.dart';
import '../logging.dart';
import '../protocol_common.dart';
import '../protocol_converter.dart';
import '../protocol_generated.dart';
import '../protocol_stream.dart';

/// The mime type to send with source responses to the client.
///
/// This is used so if the source name does not end with ".dart" the client can
/// still tell which language to use (for syntax highlighting, etc.).
///
/// https://github.com/microsoft/vscode/issues/8182#issuecomment-231151640
const dartMimeType = 'text/x-dart';

/// Maximum number of toString()s to be called when responding to variables
/// requests from the client.
///
/// Setting this too high can have a performance impact, for example if the
/// client requests 500 items in a variablesRequest for a list.
const maxToStringsPerEvaluation = 10;

/// An expression that evaluates to the exception for the current thread.
///
/// In order to support some functionality like "Copy Value" in VS Code's
/// Scopes/Variables window, each variable must have a valid "evaluateName" (an
/// expression that evaluates to it). Since we show exceptions in there we use
/// this magic value as an expression that maps to it.
///
/// This is not intended to be used by the user directly, although if they
/// evaluate it as an expression and the current thread has an exception, it
/// will work.
const threadExceptionExpression = r'$_threadException';

/// Pattern for extracting useful error messages from an evaluation exception.
final _evalErrorMessagePattern = RegExp('Error: (.*)');

/// Pattern for extracting useful error messages from an unhandled exception.
final _exceptionMessagePattern = RegExp('Unhandled exception:\n(.*)');

/// Whether to subscribe to stdout/stderr through the VM Service.
///
/// This is set by [attachRequest] so that any output will still be captured and
/// sent to the client without needing to access the process.
///
/// [launchRequest] reads the stdout/stderr streams directly and does not need
/// to have them sent via the VM Service.
var _subscribeToOutputStreams = false;

/// Pattern for a trailing semicolon.
final _trailingSemicolonPattern = RegExp(r';$');

/// An implementation of [AttachRequestArguments] that includes all fields used
/// by the base Dart debug adapter.
///
/// This class represents the data passed from the client editor to the debug
/// adapter in attachRequest, which is a request to start debugging an
/// application.
///
/// Specialised adapters (such as Flutter) will likely have their own versions
/// of this class.
class DartAttachRequestArguments extends DartCommonLaunchAttachRequestArguments
    implements AttachRequestArguments {
  /// The VM Service URI to attach to.
  ///
  /// Either this or [vmServiceInfoFile] must be supplied.
  final String? vmServiceUri;

  /// The VM Service info file to extract the VM Service URI from to attach to.
  ///
  /// Either this or [vmServiceUri] must be supplied.
  final String? vmServiceInfoFile;

  DartAttachRequestArguments({
    this.vmServiceUri,
    this.vmServiceInfoFile,
    Object? restart,
    String? name,
    String? cwd,
    List<String>? additionalProjectPaths,
    bool? debugSdkLibraries,
    bool? debugExternalPackageLibraries,
    bool? evaluateGettersInDebugViews,
    bool? evaluateToStringInDebugViews,
    bool? sendLogsToClient,
  }) : super(
          name: name,
          cwd: cwd,
          restart: restart,
          additionalProjectPaths: additionalProjectPaths,
          debugSdkLibraries: debugSdkLibraries,
          debugExternalPackageLibraries: debugExternalPackageLibraries,
          evaluateGettersInDebugViews: evaluateGettersInDebugViews,
          evaluateToStringInDebugViews: evaluateToStringInDebugViews,
          sendLogsToClient: sendLogsToClient,
        );

  DartAttachRequestArguments.fromMap(Map<String, Object?> obj)
      : vmServiceUri = obj['vmServiceUri'] as String?,
        vmServiceInfoFile = obj['vmServiceInfoFile'] as String?,
        super.fromMap(obj);

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        if (vmServiceUri != null) 'vmServiceUri': vmServiceUri,
        if (vmServiceInfoFile != null) 'vmServiceInfoFile': vmServiceInfoFile,
      };

  static DartAttachRequestArguments fromJson(Map<String, Object?> obj) =>
      DartAttachRequestArguments.fromMap(obj);
}

/// A common base for [DartLaunchRequestArguments] and
/// [DartAttachRequestArguments] for fields that are common to both.
class DartCommonLaunchAttachRequestArguments extends RequestArguments {
  /// Optional data from the previous, restarted session.
  /// The data is sent as the 'restart' attribute of the 'terminated' event.
  /// The client should leave the data intact.
  final Object? restart;

  final String? name;
  final String? cwd;

  /// Paths that should be considered the users local code.
  ///
  /// These paths will generally be all of the open folders in the users editor
  /// and are used to determine whether a library is "external" or not to
  /// support debugging "just my code" where SDK/Pub package code will be marked
  /// as not-debuggable.
  final List<String>? additionalProjectPaths;

  /// Whether SDK libraries should be marked as debuggable.
  ///
  /// Treated as `false` if null, which means "step in" will not step into SDK
  /// libraries.
  final bool? debugSdkLibraries;

  /// Whether external package libraries should be marked as debuggable.
  ///
  /// Treated as `false` if null, which means "step in" will not step into
  /// libraries in packages that are not either the local package or a path
  /// dependency. This allows users to debug "just their code" and treat Pub
  /// packages as block boxes.
  final bool? debugExternalPackageLibraries;

  /// Whether to evaluate getters in debug views like hovers and the variables
  /// list.
  ///
  /// Invoking getters has a performance cost and may introduce side-effects,
  /// although users may expected this functionality. null is treated like false
  /// although clients may have their own defaults (for example Dart-Code sends
  /// true by default at the time of writing).
  final bool? evaluateGettersInDebugViews;

  /// Whether to call toString() on objects in debug views like hovers and the
  /// variables list.
  ///
  /// Invoking toString() has a performance cost and may introduce side-effects,
  /// although users may expected this functionality. null is treated like false
  /// although clients may have their own defaults (for example Dart-Code sends
  /// true by default at the time of writing).
  final bool? evaluateToStringInDebugViews;

  /// Whether to send debug logging to clients in a custom `dart.log` event. This
  /// is used both by the out-of-process tests to ensure the logs contain enough
  /// information to track down issues, but also by Dart-Code to capture VM
  /// service traffic in a unified log file.
  final bool? sendLogsToClient;

  DartCommonLaunchAttachRequestArguments({
    required this.restart,
    required this.name,
    required this.cwd,
    required this.additionalProjectPaths,
    required this.debugSdkLibraries,
    required this.debugExternalPackageLibraries,
    required this.evaluateGettersInDebugViews,
    required this.evaluateToStringInDebugViews,
    required this.sendLogsToClient,
  });

  DartCommonLaunchAttachRequestArguments.fromMap(Map<String, Object?> obj)
      : restart = obj['restart'],
        name = obj['name'] as String?,
        cwd = obj['cwd'] as String?,
        additionalProjectPaths =
            (obj['additionalProjectPaths'] as List?)?.cast<String>(),
        debugSdkLibraries = obj['debugSdkLibraries'] as bool?,
        debugExternalPackageLibraries =
            obj['debugExternalPackageLibraries'] as bool?,
        evaluateGettersInDebugViews =
            obj['evaluateGettersInDebugViews'] as bool?,
        evaluateToStringInDebugViews =
            obj['evaluateToStringInDebugViews'] as bool?,
        sendLogsToClient = obj['sendLogsToClient'] as bool?;

  Map<String, Object?> toJson() => {
        if (restart != null) 'restart': restart,
        if (name != null) 'name': name,
        if (cwd != null) 'cwd': cwd,
        if (additionalProjectPaths != null)
          'additionalProjectPaths': additionalProjectPaths,
        if (debugSdkLibraries != null) 'debugSdkLibraries': debugSdkLibraries,
        if (debugExternalPackageLibraries != null)
          'debugExternalPackageLibraries': debugExternalPackageLibraries,
        if (evaluateGettersInDebugViews != null)
          'evaluateGettersInDebugViews': evaluateGettersInDebugViews,
        if (evaluateToStringInDebugViews != null)
          'evaluateToStringInDebugViews': evaluateToStringInDebugViews,
        if (sendLogsToClient != null) 'sendLogsToClient': sendLogsToClient,
      };
}

/// A base DAP Debug Adapter implementation for running and debugging Dart-based
/// applications (including Flutter and Tests).
///
/// This class implements all functionality common to Dart, Flutter and Test
/// debug sessions, including things like breakpoints and expression eval.
///
/// Sub-classes should handle the launching/attaching of apps and any custom
/// behaviour (such as Flutter's Hot Reload). This is generally done by overriding
/// `fooImpl` methods that are called during the handling of a `fooRequest` from
/// the client.
///
/// A DebugAdapter instance will be created per application being debugged (in
/// multi-session mode, one DebugAdapter corresponds to one incoming TCP
/// connection, though a client may make multiple of these connections if it
/// wants to debug multiple scripts concurrently, such as with a compound launch
/// configuration in VS Code).
///
/// The lifecycle is described in the DAP spec here:
/// https://microsoft.github.io/debug-adapter-protocol/overview#initialization
///
/// In summary:
///
/// The client will create a connection to the server (which will create an
///   instance of the debug adapter) and send an `initializeRequest` message,
///   wait for the server to return a response and then an initializedEvent
/// The client will then send breakpoints and exception config
///   (`setBreakpointsRequest`, `setExceptionBreakpoints`) and then a
///   `configurationDoneRequest`.
/// Finally, the client will send a `launchRequest` or `attachRequest` to start
///   running/attaching to the script.
///
/// The client will continue to send requests during the debug session that may
/// be in response to user actions (for example changing breakpoints or typing
/// an expression into an evaluation console) or to events sent by the server
/// (for example when the server sends a `StoppedEvent` it may cause the client
/// to then send a `stackTraceRequest` or `scopesRequest` to get variables).
abstract class DartDebugAdapter<TL extends LaunchRequestArguments,
    TA extends AttachRequestArguments> extends BaseDebugAdapter<TL, TA> {
  late final DartCommonLaunchAttachRequestArguments args;
  final _debuggerInitializedCompleter = Completer<void>();
  final _configurationDoneCompleter = Completer<void>();

  /// Manages VM Isolates and their events, including fanning out any requests
  /// to set breakpoints etc. from the client to all Isolates.
  late IsolateManager _isolateManager;

  /// A helper that handlers converting to/from DAP and VM Service types.
  late ProtocolConverter _converter;

  /// All active VM Service subscriptions.
  ///
  /// TODO(dantup): This may be changed to use StreamManager as part of using
  /// DDS in this process.
  final _subscriptions = <StreamSubscription<vm.Event>>[];

  /// The VM service of the app being debugged.
  ///
  /// `null` if the session is running in noDebug mode of the connection has not
  /// yet been made.
  vm.VmServiceInterface? vmService;

  /// The DDS instance that was started and that [vmService] is connected to.
  ///
  /// `null` if the session is running in noDebug mode of the connection has not
  /// yet been made.
  DartDevelopmentService? _dds;

  /// The [InitializeRequestArguments] provided by the client in the
  /// `initialize` request.
  ///
  /// `null` if the `initialize` request has not yet been made.
  InitializeRequestArguments? _initializeArgs;

  /// Whether to use IPv6 for DAP/Debugger services.
  final bool ipv6;

  /// Whether to enable DDS for launched applications.
  final bool enableDds;

  /// Whether to enable authentication codes for the VM Service/DDS.
  final bool enableAuthCodes;

  /// A logger for printing diagnostic information.
  final Logger? logger;

  /// Whether the current debug session is an attach request (as opposed to a
  /// launch request). Not available until after launchRequest or attachRequest
  /// have been called.
  late final bool isAttach;

  /// A list of evaluateNames for InstanceRef IDs.
  ///
  /// When providing variables for fields/getters or items in maps/arrays, we
  /// need to provide an expression to the client that evaluates to that
  /// variable so that functionality like "Add to Watch" or "Copy Value" can
  /// work. For example, if a user expands a list named `myList` then the 1st
  /// [Variable] returned should have an evaluateName of `myList[0]`. The `foo`
  /// getter of that object would then have an evaluateName of `myList[0].foo`.
  ///
  /// Since those expressions aren't round-tripped as child variables are
  /// requested we build them up as we send variables out, so we can append to
  /// them when returning elements/map entries/fields/getters.
  final _evaluateNamesForInstanceRefIds = <String, String>{};

  /// A list of all possible project paths that should be considered the users
  /// own code.
  ///
  /// This is made up of the folder containing the 'program' being executed, the
  /// 'cwd' and any 'additionalProjectPaths' from the launch arguments.
  late final List<String> projectPaths = [
    args.cwd,
    if (args is DartLaunchRequestArguments)
      path.dirname((args as DartLaunchRequestArguments).program),
    ...?args.additionalProjectPaths,
  ].whereNotNull().toList();

  /// Whether we have already sent the [TerminatedEvent] to the client.
  ///
  /// This is tracked so that we don't send multiple if there are multiple
  /// events that suggest the session ended (such as a process exiting and the
  /// VM Service closing).
  bool _hasSentTerminatedEvent = false;

  late final sendLogsToClient = args.sendLogsToClient ?? false;

  DartDebugAdapter(
    ByteStreamServerChannel channel, {
    this.ipv6 = false,
    this.enableDds = true,
    this.enableAuthCodes = true,
    this.logger,
  }) : super(channel) {
    channel.closed.then((_) => shutdown());

    _isolateManager = IsolateManager(this);
    _converter = ProtocolConverter(this);
  }

  /// Completes when the debugger initialization has completed. Used to delay
  /// processing isolate events while initialization is still running to avoid
  /// race conditions (for example if an isolate unpauses before we have
  /// processed its initial paused state).
  Future<void> get debuggerInitialized => _debuggerInitializedCompleter.future;

  bool get evaluateToStringInDebugViews =>
      args.evaluateToStringInDebugViews ?? false;

  /// The [InitializeRequestArguments] provided by the client in the
  /// `initialize` request.
  ///
  /// `null` if the `initialize` request has not yet been made.
  InitializeRequestArguments? get initializeArgs => _initializeArgs;

  /// Whether or not this adapter can handle the restartRequest.
  ///
  /// If false, the editor will just terminate the debug session and start a new
  /// one when the user asks to restart. If true, the adapter must implement
  /// the [restartRequest] method and handle its own restart (for example the
  /// Flutter adapter will perform a Hot Restart).
  bool get supportsRestartRequest => false;

  /// Whether the VM Service closing should be used as a signal to terminate the
  /// debug session.
  ///
  /// It is generally better to handle termination when the debuggee terminates
  /// instead, since this ensures the stdout/stderr streams have been drained.
  /// However, that's not possible in some cases (for example 'runInTerminal'
  /// or attaching), so this is the only signal we have.
  ///
  /// It is up to the subclass DA to provide this value correctly based on
  /// whether it will call [handleSessionTerminate] itself upon process
  /// termination.
  bool get terminateOnVmServiceClose;

  /// Overridden by sub-classes to handle when the client sends an
  /// `attachRequest` (a request to attach to a running app).
  ///
  /// Sub-classes can use the [args] field to access the arguments provided
  /// to this request.
  Future<void> attachImpl();

  /// [attachRequest] is called by the client when it wants us to to attach to
  /// an existing app. This will only be called once (and only one of this or
  /// launchRequest will be called).
  @override
  Future<void> attachRequest(
    Request request,
    TA args,
    void Function() sendResponse,
  ) async {
    this.args = args as DartCommonLaunchAttachRequestArguments;
    isAttach = true;
    _subscribeToOutputStreams = true;

    // Common setup.
    await _prepareForLaunchOrAttach(null);

    // Delegate to the sub-class to attach to the process.
    await attachImpl();

    sendResponse();
  }

  /// Builds an evaluateName given a parent VM InstanceRef ID and a suffix.
  ///
  /// If [parentInstanceRefId] is `null`, or we have no evaluateName for it,
  /// will return null.
  String? buildEvaluateName(
    String suffix, {
    required String? parentInstanceRefId,
  }) {
    final parentEvaluateName =
        _evaluateNamesForInstanceRefIds[parentInstanceRefId];
    return combineEvaluateName(parentEvaluateName, suffix);
  }

  /// Builds an evaluateName given a prefix and a suffix.
  ///
  /// If [prefix] is null, will return be null.
  String? combineEvaluateName(String? prefix, String suffix) {
    return prefix != null ? '$prefix$suffix' : null;
  }

  /// configurationDone is called by the client when it has finished sending
  /// any initial configuration (such as breakpoints and exception pause
  /// settings).
  ///
  /// We delay processing `launchRequest`/`attachRequest` until this request has
  /// been sent to ensure we're not still getting breakpoints (which are sent
  /// per-file) while we're launching and initializing over the VM Service.
  @override
  Future<void> configurationDoneRequest(
    Request request,
    ConfigurationDoneArguments? args,
    void Function() sendResponse,
  ) async {
    _configurationDoneCompleter.complete();
    sendResponse();
  }

  /// Connects to the VM Service at [uri] and initializes debugging.
  ///
  /// This method will be called by sub-classes when they are ready to start
  /// a debug session and may provide a URI given by the user (in the case
  /// of attach) or from something like a vm-service-info file or Flutter
  /// app.debugPort message.
  ///
  /// The URI protocol will be changed to ws/wss but otherwise not normalised.
  /// The caller should handle any other normalisation (such as adding /ws to
  /// the end if required).
  ///
  /// If [resumeIfStarting] is true, isolates waiting to start will
  /// automatically be resumed. This is usually desired in launch requests, but
  /// not when attaching.
  Future<void> connectDebugger(
    Uri uri, {
    required bool resumeIfStarting,
  }) async {
    // Start up a DDS instance for this VM.
    if (enableDds) {
      logger?.call('Starting a DDS instance for $uri');
      try {
        final dds = await DartDevelopmentService.startDartDevelopmentService(
          vmServiceUriToHttp(uri),
          enableAuthCodes: enableAuthCodes,
          ipv6: ipv6,
        );
        _dds = dds;
        uri = dds.wsUri!;
      } on DartDevelopmentServiceException catch (e) {
        // If there's already a DDS instance, then just continue. This is common
        // when attaching, as the program may have already been run with a DDS
        // instance.
        if (e.errorCode ==
            DartDevelopmentServiceException.existingDdsInstanceError) {
          uri = vmServiceUriToWebSocket(uri);
        } else {
          rethrow;
        }
      }
    } else {
      uri = vmServiceUriToWebSocket(uri);
    }

    logger?.call('Connecting to debugger at $uri');
    sendOutput('console', 'Connecting to VM Service at $uri\n');
    final vmService = await _vmServiceConnectUri(uri.toString());
    logger?.call('Connected to debugger at $uri!');

    // Send a custom event with the VM Service URI as the editor might want to
    // know about this (for example so it can connect an embedded DevTools to
    // this app).
    sendEvent(
      RawEventBody({
        'vmServiceUri': uri.toString(),
      }),
      eventType: 'dart.debuggerUris',
    );

    this.vmService = vmService;

    unawaited(vmService.onDone.then((_) => _handleVmServiceClosed()));
    _subscriptions.addAll([
      vmService.onIsolateEvent.listen(handleIsolateEvent),
      vmService.onDebugEvent.listen(handleDebugEvent),
      vmService.onLoggingEvent.listen(handleLoggingEvent),
      vmService.onExtensionEvent.listen(handleExtensionEvent),
      vmService.onServiceEvent.listen(handleServiceEvent),
      if (_subscribeToOutputStreams)
        vmService.onStdoutEvent.listen(_handleStdoutEvent),
      if (_subscribeToOutputStreams)
        vmService.onStderrEvent.listen(_handleStderrEvent),
    ]);
    await Future.wait([
      vmService.streamListen(vm.EventStreams.kIsolate),
      vmService.streamListen(vm.EventStreams.kDebug),
      vmService.streamListen(vm.EventStreams.kLogging),
      vmService.streamListen(vm.EventStreams.kExtension),
      vmService.streamListen(vm.EventStreams.kService),
      vmService.streamListen(vm.EventStreams.kStdout),
      vmService.streamListen(vm.EventStreams.kStderr),
    ]);

    final vmInfo = await vmService.getVM();
    logger?.call('Connected to ${vmInfo.name} on ${vmInfo.operatingSystem}');

    // Let the subclass do any existing setup once we have a connection.
    await debuggerConnected(vmInfo);

    // Process any existing isolates that may have been created before the
    // streams above were set up.
    final existingIsolateRefs = vmInfo.isolates;
    final existingIsolates = existingIsolateRefs != null
        ? await Future.wait(existingIsolateRefs
            .map((isolateRef) => isolateRef.id)
            .whereNotNull()
            .map(vmService.getIsolate))
        : <vm.Isolate>[];
    await Future.wait(existingIsolates.map((isolate) async {
      // Isolates may have the "None" pauseEvent kind at startup, so infer it
      // from the runnable field.
      final pauseEventKind = isolate.runnable ?? false
          ? vm.EventKind.kIsolateRunnable
          : vm.EventKind.kIsolateStart;
      final thread =
          await _isolateManager.registerIsolate(isolate, pauseEventKind);

      // If the Isolate already has a Pause event we can give it to the
      // IsolateManager to handle (if it's PausePostStart it will re-configure
      // the isolate before resuming), otherwise we can just resume it (if it's
      // runnable - otherwise we'll handle this when it becomes runnable in an
      // event later).
      if (isolate.pauseEvent?.kind?.startsWith('Pause') ?? false) {
        await _isolateManager.handleEvent(
          isolate.pauseEvent!,
          resumeIfStarting: resumeIfStarting,
        );
      } else if (isolate.runnable == true) {
        // If requested, automatically resume. Otherwise send a Stopped event to
        // inform the client UI the thread is paused.
        if (resumeIfStarting) {
          await _isolateManager.resumeIsolate(isolate);
        } else {
          _isolateManager.sendStoppedOnEntryEvent(thread.threadId);
        }
      }
    }));

    _debuggerInitializedCompleter.complete();
  }

  /// Handles the clients "continue" ("resume") request for the thread in
  /// [args.threadId].
  @override
  Future<void> continueRequest(
    Request request,
    ContinueArguments args,
    void Function(ContinueResponseBody) sendResponse,
  ) async {
    await _isolateManager.resumeThread(args.threadId);
    sendResponse(ContinueResponseBody(allThreadsContinued: false));
  }

  /// [customRequest] handles any messages that do not match standard messages
  /// in the spec.
  ///
  /// This is used to allow a client/DA to have custom methods outside of the
  /// spec. It is up to the client/DA to negotiate which custom messages are
  /// allowed.
  ///
  /// Implementations of this method must call super for any requests they are
  /// not handling. The base implementation will reject the request as unknown.
  ///
  /// Custom message starting with _ are considered internal and are liable to
  /// change without warning.
  @override
  Future<void> customRequest(
    Request request,
    RawRequestArguments? args,
    void Function(Object?) sendResponse,
  ) async {
    switch (request.command) {

      /// Used by tests to validate available protocols (e.g. DDS). There may be
      /// value in making this available to clients in future, but for now it's
      /// internal.
      case '_getSupportedProtocols':
        final protocols = await vmService?.getSupportedProtocols();
        sendResponse(protocols?.toJson());
        break;

      /// Used to toggle debug settings such as whether SDK/Packages are
      /// debuggable while the session is in progress.
      case 'updateDebugOptions':
        if (args != null) {
          await _updateDebugOptions(args.args);
        }
        sendResponse(null);
        break;

      /// Allows an editor to call a service/service extension that it was told
      /// about via a custom 'dart.serviceRegistered' or
      /// 'dart.serviceExtensionAdded' event.
      case 'callService':
        final method = args?.args['method'] as String?;
        if (method == null) {
          throw DebugAdapterException(
            'Method is required to call services/service extensions',
          );
        }
        final params = args?.args['params'] as Map<String, Object?>?;
        final response = await vmService?.callServiceExtension(
          method,
          args: params,
        );
        sendResponse(response?.json);
        break;

      default:
        await super.customRequest(request, args, sendResponse);
    }
  }

  /// Overridden by sub-classes to perform any additional setup after the VM
  /// Service is connected.
  Future<void> debuggerConnected(vm.VM vmInfo);

  /// Overridden by sub-classes to handle when the client sends a
  /// `disconnectRequest` (a forceful request to shut down).
  Future<void> disconnectImpl();

  /// [disconnectRequest] is called by the client when it wants to forcefully shut
  /// us down quickly. This comes after the `terminateRequest` which is intended
  /// to allow a graceful shutdown.
  ///
  /// It's not very obvious from the names, but `terminateRequest` is sent first
  /// (a request for a graceful shutdown) and `disconnectRequest` second (a
  /// request for a forced shutdown).
  ///
  /// https://microsoft.github.io/debug-adapter-protocol/overview#debug-session-end
  @override
  Future<void> disconnectRequest(
    Request request,
    DisconnectArguments? args,
    void Function() sendResponse,
  ) async {
    await disconnectImpl();
    await shutdown();
    sendResponse();
  }

  /// evaluateRequest is called by the client to evaluate a string expression.
  ///
  /// This could come from the user typing into an input (for example VS Code's
  /// Debug Console), automatic refresh of a Watch window, or called as part of
  /// an operation like "Copy Value" for an item in the watch/variables window.
  ///
  /// If execution is not paused, the `frameId` will not be provided.
  @override
  Future<void> evaluateRequest(
    Request request,
    EvaluateArguments args,
    void Function(EvaluateResponseBody) sendResponse,
  ) async {
    final frameId = args.frameId;
    // TODO(dantup): Special handling for clipboard/watch (see Dart-Code DAP) to
    // avoid wrapping strings in quotes, etc.

    // If the frameId was supplied, it maps to an ID we provided from stored
    // data so we need to look up the isolate + frame index for it.
    ThreadInfo? thread;
    int? frameIndex;
    if (frameId != null) {
      final data = _isolateManager.getStoredData(frameId);
      if (data != null) {
        thread = data.thread;
        frameIndex = (data.data as vm.Frame).index;
      }
    }

    if (thread == null || frameIndex == null) {
      // TODO(dantup): Dart-Code evaluates these in the context of the rootLib
      // rather than just not supporting it. Consider something similar (or
      // better here).
      throw UnimplementedError('Global evaluation not currently supported');
    }

    // The value in the constant `frameExceptionExpression` is used as a special
    // expression that evaluates to the exception on the current thread. This
    // allows us to construct evaluateNames that evaluate to the fields down the
    // tree to support some of the debugger functionality (for example
    // "Copy Value", which re-evaluates).
    final expression = args.expression
        .trim()
        // Remove any trailing semicolon as the VM only evaluates expressions
        // but a user may have highlighted a whole line/statement to send for
        // evaluation.
        .replaceFirst(_trailingSemicolonPattern, '');
    final exceptionReference = thread.exceptionReference;
    final isExceptionExpression = expression == threadExceptionExpression ||
        expression.startsWith('$threadExceptionExpression.');

    vm.Response? result;
    try {
      if (exceptionReference != null && isExceptionExpression) {
        result = await _evaluateExceptionExpression(
          exceptionReference,
          expression,
          thread,
        );
      } else {
        result = await vmService?.evaluateInFrame(
          thread.isolate.id!,
          frameIndex,
          expression,
          disableBreakpoints: true,
        );
      }
    } catch (e) {
      final rawMessage = '$e';

      // Error messages can be quite verbose and don't fit well into a
      // single-line watch window. For example:
      //
      //    evaluateInFrame: (113) Expression compilation error
      //    org-dartlang-debug:synthetic_debug_expression:1:5: Error: A value of type 'String' can't be assigned to a variable of type 'num'.
      //    1 + "a"
      //        ^
      //
      // So in the case of a Watch context, try to extract the useful message.
      if (args.context == 'watch') {
        throw DebugAdapterException(extractEvaluationErrorMessage(rawMessage));
      }

      throw DebugAdapterException(rawMessage);
    }

    if (result is vm.ErrorRef) {
      throw DebugAdapterException(result.message ?? '<error ref>');
    } else if (result is vm.Sentinel) {
      throw DebugAdapterException(result.valueAsString ?? '<collected>');
    } else if (result is vm.InstanceRef) {
      final resultString = await _converter.convertVmInstanceRefToDisplayString(
        thread,
        result,
        allowCallingToString: evaluateToStringInDebugViews,
      );

      final variablesReference =
          _converter.isSimpleKind(result.kind) ? 0 : thread.storeData(result);

      // Store the expression that gets this object as we may need it to
      // compute evaluateNames for child objects later.
      storeEvaluateName(result, expression);

      sendResponse(EvaluateResponseBody(
        result: resultString,
        variablesReference: variablesReference,
      ));
    } else {
      throw DebugAdapterException(
        'Unknown evaluation response type: ${result?.runtimeType}',
      );
    }
  }

  /// Tries to extract the useful part from an evaluation exception message.
  ///
  /// If no message could be extracted, returns the whole original error.
  String extractEvaluationErrorMessage(String rawError) {
    final match = _evalErrorMessagePattern.firstMatch(rawError);
    final shortError = match != null ? match.group(1)! : null;
    return shortError ?? rawError;
  }

  /// Tries to extract the useful part from an unhandled exception message.
  ///
  /// If no message could be extracted, returns the whole original error.
  String extractUnhandledExceptionMessage(String rawError) {
    final match = _exceptionMessagePattern.firstMatch(rawError);
    final shortError = match != null ? match.group(1)! : null;
    return shortError ?? rawError;
  }

  /// Sends a [TerminatedEvent] if one has not already been sent.
  void handleSessionTerminate([String exitSuffix = '']) {
    if (_hasSentTerminatedEvent) {
      return;
    }

    _hasSentTerminatedEvent = true;
    // Always add a leading newline since the last written text might not have
    // had one.
    sendOutput('console', '\nExited$exitSuffix.');
    sendEvent(TerminatedEventBody());
  }

  /// [initializeRequest] is the first call from the client during
  /// initialization and allows exchanging capabilities and configuration
  /// between client and server.
  ///
  /// The lifecycle is described in the DAP spec here:
  /// https://microsoft.github.io/debug-adapter-protocol/overview#initialization
  /// with a summary in this classes description.
  @override
  Future<void> initializeRequest(
    Request request,
    InitializeRequestArguments args,
    void Function(Capabilities) sendResponse,
  ) async {
    // Capture args so we can read capabilities later.
    _initializeArgs = args;

    // TODO(dantup): Capture/honor editor-specific settings like linesStartAt1
    sendResponse(Capabilities(
      exceptionBreakpointFilters: [
        ExceptionBreakpointsFilter(
          filter: 'All',
          label: 'All Exceptions',
          defaultValue: false,
        ),
        ExceptionBreakpointsFilter(
          filter: 'Unhandled',
          label: 'Uncaught Exceptions',
          defaultValue: true,
        ),
      ],
      supportsClipboardContext: true,
      supportsConditionalBreakpoints: true,
      supportsConfigurationDoneRequest: true,
      supportsDelayedStackTraceLoading: true,
      supportsEvaluateForHovers: true,
      supportsLogPoints: true,
      supportsRestartRequest: supportsRestartRequest,
      // TODO(dantup): All of these...
      // supportsRestartFrame: true,
      supportsTerminateRequest: true,
    ));

    // This must only be sent AFTER the response!
    sendEvent(InitializedEventBody());
  }

  /// Checks whether this library is from an external package.
  ///
  /// This is used to support debugging "Just My Code" so Pub packages can be
  /// marked as not-debuggable.
  ///
  /// A library is considered local if the path is within the 'cwd' or
  /// 'additionalProjectPaths' in the launch arguments. An editor should include
  /// the paths of all open workspace folders in 'additionalProjectPaths' to
  /// support this feature correctly.
  bool isExternalPackageLibrary(Uri uri) {
    if (!uri.isScheme('package')) {
      return false;
    }
    final libraryPath = resolvePackageUri(uri);
    if (libraryPath == null) {
      return false;
    }

    // Always compare paths case-insensitively to avoid any issues where APIs
    // may have returned different casing (e.g. Windows drive letters). It's
    // almost certain a user wouldn't have a "local" package and an "external"
    // package with paths differing only be case.
    final libraryPathLower = libraryPath.toLowerCase();
    return !projectPaths.any((projectPath) =>
        path.isWithin(projectPath.toLowerCase(), libraryPathLower));
  }

  /// Checks whether this library is from the SDK.
  bool isSdkLibrary(Uri uri) => uri.isScheme('dart');

  /// Overridden by sub-classes to handle when the client sends a
  /// `launchRequest` (a request to start running/debugging an app).
  ///
  /// Sub-classes can use the [args] field to access the arguments provided
  /// to this request.
  Future<void> launchImpl();

  /// [launchRequest] is called by the client when it wants us to to start the app
  /// to be run/debug. This will only be called once (and only one of this or
  /// [attachRequest] will be called).
  @override
  Future<void> launchRequest(
    Request request,
    TL args,
    void Function() sendResponse,
  ) async {
    this.args = args as DartCommonLaunchAttachRequestArguments;
    isAttach = false;

    // Common setup.
    await _prepareForLaunchOrAttach(args.noDebug);

    // Delegate to the sub-class to launch the process.
    await launchImpl();

    sendResponse();
  }

  /// Checks whether a library URI should be considered debuggable.
  ///
  /// Initial values are provided in the launch arguments, but may be updated
  /// by the `updateDebugOptions` custom request.
  bool libaryIsDebuggable(Uri uri) {
    if (isSdkLibrary(uri)) {
      return _isolateManager.debugSdkLibraries;
    } else if (isExternalPackageLibrary(uri)) {
      return _isolateManager.debugExternalPackageLibraries;
    } else {
      return true;
    }
  }

  /// Handles the clients "next" ("step over") request for the thread in
  /// [args.threadId].
  @override
  Future<void> nextRequest(
    Request request,
    NextArguments args,
    void Function() sendResponse,
  ) async {
    await _isolateManager.resumeThread(args.threadId, vm.StepOption.kOver);
    sendResponse();
  }

  /// Resolves a `package: URI` to the real underlying source path.
  ///
  /// Returns `null` if no mapping was possible, for example if the package is
  /// not in the package mapping file.
  String? resolvePackageUri(Uri uri) => _converter.resolvePackageUri(uri);

  /// restart is called by the client when the user invokes a restart (for
  /// example with the button on the debug toolbar).
  ///
  /// The base implementation of this method throws. It is up to a debug adapter
  /// that advertises `supportsRestartRequest` to override this method.
  @override
  Future<void> restartRequest(
    Request request,
    RestartArguments? args,
    void Function() sendResponse,
  ) async {
    throw DebugAdapterException(
      'restartRequest was called on an adapter that '
      'does not provide an implementation',
    );
  }

  /// [scopesRequest] is called by the client to request all of the variables
  /// scopes available for a given stack frame.
  @override
  Future<void> scopesRequest(
    Request request,
    ScopesArguments args,
    void Function(ScopesResponseBody) sendResponse,
  ) async {
    final scopes = <Scope>[];

    // For local variables, we can just reuse the frameId as variablesReference
    // as variablesRequest handles stored data of type `Frame` directly.
    scopes.add(Scope(
      name: 'Locals',
      presentationHint: 'locals',
      variablesReference: args.frameId,
      expensive: false,
    ));

    // If the top frame has an exception, add an additional section to allow
    // that to be inspected.
    final data = _isolateManager.getStoredData(args.frameId);
    final exceptionReference = data?.thread.exceptionReference;
    if (exceptionReference != null) {
      scopes.add(Scope(
        name: 'Exceptions',
        variablesReference: exceptionReference,
        expensive: false,
      ));
    }

    sendResponse(ScopesResponseBody(scopes: scopes));
  }

  /// Sends an OutputEvent (without a newline, since calls to this method
  /// may be used by buffered data).
  void sendOutput(String category, String message) {
    sendEvent(OutputEventBody(category: category, output: message));
  }

  /// Sends an OutputEvent for [message], prefixed with [prefix] and with [message]
  /// indented to after the prefix.
  ///
  /// Assumes the output is in full lines and will always include a terminating
  /// newline.
  void sendPrefixedOutput(String category, String prefix, String message) {
    final indentString = ' ' * prefix.length;
    final indentedMessage =
        message.trimRight().split('\n').join('\n$indentString');
    sendOutput(category, '$prefix$indentedMessage\n');
  }

  /// Handles a request from the client to set breakpoints.
  ///
  /// This method can be called at any time (before the app is launched or while
  /// the app is running) and will include the new full set of breakpoints for
  /// the file URI in [args.source.path].
  ///
  /// The VM requires breakpoints to be set per-isolate so these will be passed
  /// to [_isolateManager] that will fan them out to each isolate.
  ///
  /// When new isolates are registered, it is [isolateManager]'s responsibility
  /// to ensure all breakpoints are given to them (and like at startup, this
  /// must happen before they are resumed).
  @override
  Future<void> setBreakpointsRequest(
    Request request,
    SetBreakpointsArguments args,
    void Function(SetBreakpointsResponseBody) sendResponse,
  ) async {
    final breakpoints = args.breakpoints ?? [];

    final path = args.source.path;
    final name = args.source.name;
    final uri = path != null ? Uri.file(path).toString() : name!;

    await _isolateManager.setBreakpoints(uri, breakpoints);

    // TODO(dantup): Handle breakpoint resolution rather than pretending all
    // breakpoints are verified immediately.
    sendResponse(SetBreakpointsResponseBody(
      breakpoints: breakpoints.map((e) => Breakpoint(verified: true)).toList(),
    ));
  }

  /// Handles a request from the client to set exception pause modes.
  ///
  /// This method can be called at any time (before the app is launched or while
  /// the app is running).
  ///
  /// The VM requires exception modes to be set per-isolate so these will be
  /// passed to [_isolateManager] that will fan them out to each isolate.
  ///
  /// When new isolates are registered, it is [isolateManager]'s responsibility
  /// to ensure the pause mode is given to them (and like at startup, this
  /// must happen before they are resumed).
  @override
  Future<void> setExceptionBreakpointsRequest(
    Request request,
    SetExceptionBreakpointsArguments args,
    void Function(SetExceptionBreakpointsResponseBody) sendResponse,
  ) async {
    final mode = args.filters.contains('All')
        ? 'All'
        : args.filters.contains('Unhandled')
            ? 'Unhandled'
            : 'None';

    await _isolateManager.setExceptionPauseMode(mode);

    sendResponse(SetExceptionBreakpointsResponseBody());
  }

  /// Shuts down and cleans up.
  ///
  /// This is called by [disconnectRequest] and [terminateRequest] but may also
  /// be called if the client just disconnects from the server without calling
  /// either.
  ///
  /// This method must tolerate being called multiple times.
  @mustCallSuper
  Future<void> shutdown() async {
    await _dds?.shutdown();
  }

  /// [sourceRequest] is called by the client to request source code for a given
  /// source.
  ///
  /// The client may provide a whole source or just an int sourceReference (the
  /// spec originally had only sourceReference but now supports whole sources).
  ///
  /// The supplied sourceReference should correspond to a ScriptRef instance
  /// that was stored to generate the sourceReference when sent to the client.
  @override
  Future<void> sourceRequest(
    Request request,
    SourceArguments args,
    void Function(SourceResponseBody) sendResponse,
  ) async {
    final storedData = _isolateManager.getStoredData(
      args.source?.sourceReference ?? args.sourceReference,
    );
    if (storedData == null) {
      throw StateError('source reference is no longer valid');
    }
    final thread = storedData.thread;
    final data = storedData.data;
    final scriptRef = data is vm.ScriptRef ? data : null;
    if (scriptRef == null) {
      throw StateError('source reference was not a valid script');
    }

    final script = await thread.getScript(scriptRef);
    final scriptSource = script.source;
    if (scriptSource == null) {
      throw DebugAdapterException('<source not available>');
    }

    sendResponse(
      SourceResponseBody(content: scriptSource, mimeType: dartMimeType),
    );
  }

  /// Handles a request from the client for the call stack for [args.threadId].
  ///
  /// This is usually called after we sent a [StoppedEvent] to the client
  /// notifying it that execution of an isolate has paused and it wants to
  /// populate the call stack view.
  ///
  /// Clients may fetch the frames in batches and VS Code in particular will
  /// send two requests initially - one for the top frame only, and then one for
  /// the next 19 frames. For better performance, the first request is satisfied
  /// entirely from the threads pauseEvent.topFrame so we do not need to
  /// round-trip to the VM Service.
  @override
  Future<void> stackTraceRequest(
    Request request,
    StackTraceArguments args,
    void Function(StackTraceResponseBody) sendResponse,
  ) async {
    // We prefer to provide frames in small batches. Rather than tell the client
    // how many frames there really are (which can be expensive to compute -
    // especially for web) we just add 20 on to the last frame we actually send,
    // as described in the spec:
    //
    // "Returning monotonically increasing totalFrames values for subsequent
    //  requests can be used to enforce paging in the client."
    const stackFrameBatchSize = 20;

    final threadId = args.threadId;
    final thread = _isolateManager.getThread(threadId);
    final topFrame = thread?.pauseEvent?.topFrame;
    final startFrame = args.startFrame ?? 0;
    final numFrames = args.levels ?? 0;
    var totalFrames = 1;

    if (thread == null) {
      throw DebugAdapterException('No thread with threadId $threadId');
    }

    if (!thread.paused) {
      throw DebugAdapterException('Thread $threadId is not paused');
    }

    final stackFrames = <StackFrame>[];
    // If the request is only for the top frame, we may be able to satisfy it
    // from the threads `pauseEvent.topFrame`.
    if (startFrame == 0 && numFrames == 1 && topFrame != null) {
      totalFrames = 1 + stackFrameBatchSize;
      final dapTopFrame = await _converter.convertVmToDapStackFrame(
        thread,
        topFrame,
        isTopFrame: true,
      );
      stackFrames.add(dapTopFrame);
    } else {
      // Otherwise, send the request on to the VM.
      // The VM doesn't support fetching an arbitrary slice of frames, only a
      // maximum limit, so if the client asks for frames 20-30 we must send a
      // request for the first 30 and trim them ourselves.

      // DAP says if numFrames is 0 or missing (which we swap to 0 above) we
      // should return all.
      final limit = numFrames == 0 ? null : startFrame + numFrames;
      final stack = await vmService?.getStack(thread.isolate.id!, limit: limit);
      final frames = stack?.asyncCausalFrames ?? stack?.frames;

      if (stack != null && frames != null) {
        // When the call stack is truncated, we always add [stackFrameBatchSize]
        // to the count, indicating to the client there are more frames and
        // the size of the batch they should request when "loading more".
        //
        // It's ok to send a number that runs past the actual end of the call
        // stack and the client should handle this gracefully:
        //
        // "a client should be prepared to receive less frames than requested,
        //  which is an indication that the end of the stack has been reached."
        totalFrames = (stack.truncated ?? false)
            ? frames.length + stackFrameBatchSize
            : frames.length;

        // Find the first async marker, because some functionality only works
        // up until the first async bounday (e.g. rewind) since we're showing
        // the user async frames which are out-of-sync with the real frames
        // past that point.
        final firstAsyncMarkerIndex = frames.indexWhere(
          (frame) => frame.kind == vm.FrameKind.kAsyncSuspensionMarker,
        );

        Future<StackFrame> convert(int index, vm.Frame frame) async {
          return _converter.convertVmToDapStackFrame(
            thread,
            frame,
            firstAsyncMarkerIndex: firstAsyncMarkerIndex,
            isTopFrame: startFrame == 0 && index == 0,
          );
        }

        final frameSubset = frames.sublist(startFrame);
        stackFrames.addAll(await Future.wait(frameSubset.mapIndexed(convert)));
      }
    }

    sendResponse(
      StackTraceResponseBody(
        stackFrames: stackFrames,
        totalFrames: totalFrames,
      ),
    );
  }

  /// Handles the clients "step in" request for the thread in [args.threadId].
  @override
  Future<void> stepInRequest(
    Request request,
    StepInArguments args,
    void Function() sendResponse,
  ) async {
    await _isolateManager.resumeThread(args.threadId, vm.StepOption.kInto);
    sendResponse();
  }

  /// Handles the clients "step out" request for the thread in [args.threadId].
  @override
  Future<void> stepOutRequest(
    Request request,
    StepOutArguments args,
    void Function() sendResponse,
  ) async {
    await _isolateManager.resumeThread(args.threadId, vm.StepOption.kOut);
    sendResponse();
  }

  /// Stores [evaluateName] as the expression that can be evaluated to get
  /// [instanceRef].
  void storeEvaluateName(vm.InstanceRef instanceRef, String? evaluateName) {
    if (evaluateName != null) {
      _evaluateNamesForInstanceRefIds[instanceRef.id!] = evaluateName;
    }
  }

  /// Overridden by sub-classes to handle when the client sends a
  /// `terminateRequest` (a request for a graceful shut down).
  Future<void> terminateImpl();

  /// [terminateRequest] is called by the client when it wants us to gracefully
  /// shut down.
  ///
  /// It's not very obvious from the names, but `terminateRequest` is sent first
  /// (a request for a graceful shutdown) and `disconnectRequest` second (a
  /// request for a forced shutdown).
  ///
  /// https://microsoft.github.io/debug-adapter-protocol/overview#debug-session-end
  @override
  Future<void> terminateRequest(
    Request request,
    TerminateArguments? args,
    void Function() sendResponse,
  ) async {
    await terminateImpl();
    await shutdown();
    sendResponse();
  }

  /// Handles a request from the client for the list of threads.
  ///
  /// This is usually called after we sent a [StoppedEvent] to the client
  /// notifying it that execution of an isolate has paused and it wants to
  /// populate the threads view.
  @override
  Future<void> threadsRequest(
    Request request,
    void args,
    void Function(ThreadsResponseBody) sendResponse,
  ) async {
    final threads = [
      for (final thread in _isolateManager.threads)
        Thread(
          id: thread.threadId,
          name: thread.isolate.name ?? '<unnamed isolate>',
        )
    ];
    sendResponse(ThreadsResponseBody(threads: threads));
  }

  /// Sets the package config file to use for `package: URI` resolution.
  ///
  /// TODO(dantup): Remove this once
  ///   https://github.com/dart-lang/sdk/issues/45530 is done as it will not be
  ///   necessary.
  void usePackageConfigFile(File packageConfig) {
    _converter.packageConfig = PackageConfig.parseString(
      packageConfig.readAsStringSync(),
      Uri.file(packageConfig.path),
    );
  }

  /// [variablesRequest] is called by the client to request child variables for
  /// a given variables variablesReference.
  ///
  /// The variablesReference provided by the client will be a reference the
  /// server has previously provided, for example in response to a scopesRequest
  /// or an evaluateRequest.
  ///
  /// We use the reference to look up the stored data and then create variables
  /// based on the type of data. For a Frame, we will return the local
  /// variables, for a List/MapAssociation we will return items from it, and for
  /// an instance we will return the fields (and possibly getters) for that
  /// instance.
  @override
  Future<void> variablesRequest(
    Request request,
    VariablesArguments args,
    void Function(VariablesResponseBody) sendResponse,
  ) async {
    final childStart = args.start;
    final childCount = args.count;
    final storedData = _isolateManager.getStoredData(args.variablesReference);
    if (storedData == null) {
      throw StateError('variablesReference is no longer valid');
    }
    final thread = storedData.thread;
    final data = storedData.data;
    final vmData = data is vm.Response ? data : null;
    final variables = <Variable>[];

    if (vmData is vm.Frame) {
      final vars = vmData.vars;
      if (vars != null) {
        Future<Variable> convert(int index, vm.BoundVariable variable) {
          // Store the expression that gets this object as we may need it to
          // compute evaluateNames for child objects later.
          storeEvaluateName(variable.value, variable.name);
          return _converter.convertVmResponseToVariable(
            thread,
            variable.value,
            name: variable.name,
            allowCallingToString: evaluateToStringInDebugViews &&
                index <= maxToStringsPerEvaluation,
            evaluateName: variable.name,
          );
        }

        variables.addAll(await Future.wait(vars.mapIndexed(convert)));

        // Sort the variables by name.
        variables.sortBy((v) => v.name);
      }
    } else if (data is vm.MapAssociation) {
      final key = data.key;
      final value = data.value;
      if (key is vm.InstanceRef && value is vm.InstanceRef) {
        // For a MapAssociation, we create a dummy set of variables for "key" and
        // "value" so that each may be expanded if they are complex values.
        variables.addAll([
          Variable(
            name: 'key',
            value: await _converter.convertVmInstanceRefToDisplayString(
              thread,
              key,
              allowCallingToString: evaluateToStringInDebugViews,
            ),
            variablesReference:
                _converter.isSimpleKind(key.kind) ? 0 : thread.storeData(key),
          ),
          Variable(
              name: 'value',
              value: await _converter.convertVmInstanceRefToDisplayString(
                thread,
                value,
                allowCallingToString: evaluateToStringInDebugViews,
              ),
              variablesReference: _converter.isSimpleKind(value.kind)
                  ? 0
                  : thread.storeData(value),
              evaluateName:
                  buildEvaluateName('', parentInstanceRefId: value.id)),
        ]);
      }
    } else if (vmData is vm.ObjRef) {
      final object =
          await _isolateManager.getObject(storedData.thread.isolate, vmData);

      if (object is vm.Sentinel) {
        variables.add(Variable(
          name: '<eval error>',
          value: object.valueAsString.toString(),
          variablesReference: 0,
        ));
      } else if (object is vm.Instance) {
        variables.addAll(await _converter.convertVmInstanceToVariablesList(
          thread,
          object,
          evaluateName: buildEvaluateName('', parentInstanceRefId: vmData.id),
          allowCallingToString: evaluateToStringInDebugViews,
          startItem: childStart,
          numItems: childCount,
        ));
      } else {
        variables.add(Variable(
          name: '<eval error>',
          value: object.runtimeType.toString(),
          variablesReference: 0,
        ));
      }
    }

    sendResponse(VariablesResponseBody(variables: variables));
  }

  /// Fixes up a VM Service WebSocket URI to not have a trailing /ws
  /// and use the HTTP scheme which is what DDS expects.
  Uri vmServiceUriToHttp(Uri uri) {
    final isSecure = uri.isScheme('https') || uri.isScheme('wss');
    uri = uri.replace(scheme: isSecure ? 'https' : 'http');

    final segments = uri.pathSegments;
    if (segments.isNotEmpty && segments.last == 'ws') {
      uri = uri.replace(pathSegments: segments.take(segments.length - 1));
    }

    return uri;
  }

  /// Fixes up an Observatory [uri] to a WebSocket URI with a trailing /ws
  /// for connecting when not using DDS.
  ///
  /// DDS does its own cleaning up of the URI.
  Uri vmServiceUriToWebSocket(Uri uri) {
    // The VM Service library always expects the WebSockets URI so fix the
    // scheme (http -> ws, https -> wss).
    final isSecure = uri.isScheme('https') || uri.isScheme('wss');
    uri = uri.replace(scheme: isSecure ? 'wss' : 'ws');

    if (uri.path.endsWith('/ws') || uri.path.endsWith('/ws/')) {
      return uri;
    }

    final append = uri.path.endsWith('/') ? 'ws' : '/ws';
    final newPath = '${uri.path}$append';
    return uri.replace(path: newPath);
  }

  /// Handles evaluation of an expression that is (or begins with)
  /// `threadExceptionExpression` which corresponds to the exception at the top
  /// of [thread].
  Future<vm.Response?> _evaluateExceptionExpression(
    int exceptionReference,
    String expression,
    ThreadInfo thread,
  ) async {
    final exception = _isolateManager.getStoredData(exceptionReference)?.data
        as vm.InstanceRef?;

    if (exception == null) {
      return null;
    }

    if (expression == threadExceptionExpression) {
      return exception;
    }

    // Strip the prefix off since we'll evaluate against the exception
    // by its ID.
    final expressionWithoutExceptionExpression =
        expression.substring(threadExceptionExpression.length + 1);

    return vmService?.evaluate(
      thread.isolate.id!,
      exception.id!,
      expressionWithoutExceptionExpression,
      disableBreakpoints: true,
    );
  }

  @protected
  @mustCallSuper
  Future<void> handleDebugEvent(vm.Event event) async {
    // Delay processing any events until the debugger initialization has
    // finished running, as events may arrive (for ex. IsolateRunnable) while
    // it's doing is own initialization that this may interfere with.
    await debuggerInitialized;

    await _isolateManager.handleEvent(event);
  }

  @protected
  @mustCallSuper
  Future<void> handleExtensionEvent(vm.Event event) async {
    await debuggerInitialized;

    // Base Dart does not do anything here, but other DAs (like Flutter) may
    // override it to do their own handling.
  }

  @protected
  @mustCallSuper
  Future<void> handleIsolateEvent(vm.Event event) async {
    // Delay processing any events until the debugger initialization has
    // finished running, as events may arrive (for ex. IsolateRunnable) while
    // it's doing is own initialization that this may interfere with.
    await debuggerInitialized;

    // Allow IsolateManager to handle any state-related events.
    await _isolateManager.handleEvent(event);

    switch (event.kind) {
      // Pass any Service Extension events on to the client so they can enable
      // functionality based upon them.
      case vm.EventKind.kServiceExtensionAdded:
        this._sendServiceExtensionAdded(
          event.extensionRPC!,
          event.isolate!.id!,
        );
        break;
    }
  }

  /// Handles a dart:developer log() event, sending output to the client.
  @protected
  @mustCallSuper
  Future<void> handleLoggingEvent(vm.Event event) async {
    final record = event.logRecord;
    final thread = _isolateManager.threadForIsolate(event.isolate);
    if (record == null || thread == null) {
      return;
    }

    /// Helper to convert to InstanceRef to a String, taking into account
    /// [vm.InstanceKind.kNull] which is the type for the unused fields of a
    /// log event.
    Future<String?> asString(vm.InstanceRef? ref) async {
      if (ref == null || ref.kind == vm.InstanceKind.kNull) {
        return null;
      }
      return _converter
          .convertVmInstanceRefToDisplayString(
        thread,
        ref,
        // Always allow calling toString() here as the user expects the full
        // string they logged regardless of the evaluateToStringInDebugViews
        // setting.
        allowCallingToString: true,
        allowTruncatedValue: false,
        includeQuotesAroundString: false,
      )
          .catchError((e) {
        // Fetching strings from the server may throw if they have been
        // collected since (for example if a Hot Restart occurs while
        // we're running this). Log the error and just return null so
        // nothing is shown.
        logger?.call('$e');
      });
    }

    var loggerName = await asString(record.loggerName);
    if (loggerName?.isEmpty ?? true) {
      loggerName = 'log';
    }
    final message = await asString(record.message);
    final error = await asString(record.error);
    final stack = await asString(record.stackTrace);

    final prefix = '[$loggerName] ';

    if (message != null) {
      sendPrefixedOutput('console', prefix, '$message\n');
    }
    if (error != null) {
      sendPrefixedOutput('console', prefix, '$error\n');
    }
    if (stack != null) {
      sendPrefixedOutput('console', prefix, '$stack\n');
    }
  }

  @protected
  @mustCallSuper
  Future<void> handleServiceEvent(vm.Event event) async {
    await debuggerInitialized;

    switch (event.kind) {
      // Service registrations are passed to the client so they can toggle
      // behaviour based on their presence.
      case vm.EventKind.kServiceRegistered:
        this._sendServiceRegistration(event.service!, event.method!);
        break;
      case vm.EventKind.kServiceUnregistered:
        this._sendServiceUnregistration(event.service!, event.method!);
        break;
    }
  }

  void _handleStderrEvent(vm.Event event) {
    _sendOutputStreamEvent('stderr', event);
  }

  void _handleStdoutEvent(vm.Event event) {
    _sendOutputStreamEvent('stdout', event);
  }

  Future<void> _handleVmServiceClosed() async {
    if (terminateOnVmServiceClose) {
      handleSessionTerminate();
    }
  }

  void _logTraffic(String message) {
    logger?.call(message);
    if (sendLogsToClient) {
      sendEvent(RawEventBody({"message": message}), eventType: 'dart.log');
    }
  }

  /// Performs some setup that is common to both [launchRequest] and
  /// [attachRequest].
  Future<void> _prepareForLaunchOrAttach(bool? noDebug) async {
    // Don't start launching until configurationDone.
    if (!_configurationDoneCompleter.isCompleted) {
      logger?.call('Waiting for configurationDone request...');
      await _configurationDoneCompleter.future;
    }

    // Notify IsolateManager if we'll be debugging so it knows whether to set
    // up breakpoints etc. when isolates are registered.
    final debug = !(noDebug ?? false);
    _isolateManager.debug = debug;
    _isolateManager.debugSdkLibraries = args.debugSdkLibraries ?? true;
    _isolateManager.debugExternalPackageLibraries =
        args.debugExternalPackageLibraries ?? true;
  }

  /// Sends output for a VM WriteEvent to the client.
  ///
  /// Used to pass stdout/stderr when there's no access to the streams directly.
  void _sendOutputStreamEvent(String type, vm.Event event) {
    final data = event.bytes;
    if (data == null) {
      return;
    }
    final message = utf8.decode(base64Decode(data));
    sendOutput('stdout', message);
  }

  void _sendServiceExtensionAdded(String extensionRPC, String isolateId) {
    sendEvent(
      RawEventBody({'extensionRPC': extensionRPC, 'isolateId': isolateId}),
      eventType: 'dart.serviceExtensionAdded',
    );
  }

  void _sendServiceRegistration(String service, String method) {
    sendEvent(
      RawEventBody({'service': service, 'method': method}),
      eventType: 'dart.serviceRegistered',
    );
  }

  void _sendServiceUnregistration(String service, String method) {
    sendEvent(
      RawEventBody({'service': service, 'method': method}),
      eventType: 'dart.serviceUnregistered',
    );
  }

  /// Updates the current debug options for the session.
  ///
  /// Clients may not know about all debug options, so anything not included
  /// in the map will not be updated by this method.
  Future<void> _updateDebugOptions(Map<String, Object?> args) async {
    if (args.containsKey('debugSdkLibraries')) {
      _isolateManager.debugSdkLibraries = args['debugSdkLibraries'] as bool;
    }
    if (args.containsKey('debugExternalPackageLibraries')) {
      _isolateManager.debugExternalPackageLibraries =
          args['debugExternalPackageLibraries'] as bool;
    }
    await _isolateManager.applyDebugOptions();
  }

  /// A wrapper around the same name function from package:vm_service that
  /// allows logging all traffic over the VM Service.
  Future<vm.VmService> _vmServiceConnectUri(String wsUri) async {
    final socket = await WebSocket.connect(wsUri);
    final controller = StreamController();
    final streamClosedCompleter = Completer();
    final logger = this.logger;

    socket.listen(
      (data) {
        _logTraffic('<== [VM] $data');
        controller.add(data);
      },
      onDone: () => streamClosedCompleter.complete(),
    );

    return vm.VmService(
      controller.stream,
      (String message) {
        logger?.call('==> [VM] $message');
        _logTraffic('==> [VM] $message');
        socket.add(message);
      },
      log: logger != null ? VmServiceLogger(logger) : null,
      disposeHandler: () => socket.close(),
      streamClosed: streamClosedCompleter.future,
    );
  }
}

/// An implementation of [LaunchRequestArguments] that includes all fields used
/// by the base Dart debug adapter.
///
/// This class represents the data passed from the client editor to the debug
/// adapter in launchRequest, which is a request to start debugging an
/// application.
///
/// Specialised adapters (such as Flutter) will likely have their own versions
/// of this class.
class DartLaunchRequestArguments extends DartCommonLaunchAttachRequestArguments
    implements LaunchRequestArguments {
  /// If noDebug is true the launch request should launch the program without
  /// enabling debugging.
  final bool? noDebug;

  /// The program/Dart script to be run.
  final String program;

  /// Arguments to be passed to [program].
  final List<String>? args;

  /// Arguments to be passed to the tool that will run [program] (for example,
  /// the VM or Flutter tool).
  final List<String>? toolArgs;

  final int? vmServicePort;

  final bool? enableAsserts;

  /// Which console to run the program in.
  ///
  /// If "terminal" or "externalTerminal" will cause the program to be run by
  /// the client by having the server call the `runInTerminal` request on the
  /// client (as long as the client advertises support for
  /// `runInTerminalRequest`).
  ///
  /// Otherwise will run inside the debug adapter and stdout/stderr will be
  /// routed to the client using [OutputEvent]s. This is the default (and
  /// simplest) way, but prevents the user from being able to type into `stdin`.
  final String? console;

  DartLaunchRequestArguments({
    this.noDebug,
    required this.program,
    this.args,
    this.vmServicePort,
    this.toolArgs,
    this.console,
    this.enableAsserts,
    Object? restart,
    String? name,
    String? cwd,
    List<String>? additionalProjectPaths,
    bool? debugSdkLibraries,
    bool? debugExternalPackageLibraries,
    bool? evaluateGettersInDebugViews,
    bool? evaluateToStringInDebugViews,
    bool? sendLogsToClient,
  }) : super(
          restart: restart,
          name: name,
          cwd: cwd,
          additionalProjectPaths: additionalProjectPaths,
          debugSdkLibraries: debugSdkLibraries,
          debugExternalPackageLibraries: debugExternalPackageLibraries,
          evaluateGettersInDebugViews: evaluateGettersInDebugViews,
          evaluateToStringInDebugViews: evaluateToStringInDebugViews,
          sendLogsToClient: sendLogsToClient,
        );

  DartLaunchRequestArguments.fromMap(Map<String, Object?> obj)
      : noDebug = obj['noDebug'] as bool?,
        program = obj['program'] as String,
        args = (obj['args'] as List?)?.cast<String>(),
        toolArgs = (obj['toolArgs'] as List?)?.cast<String>(),
        vmServicePort = obj['vmServicePort'] as int?,
        console = obj['console'] as String?,
        enableAsserts = obj['enableAsserts'] as bool?,
        super.fromMap(obj);

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        if (noDebug != null) 'noDebug': noDebug,
        'program': program,
        if (args != null) 'args': args,
        if (toolArgs != null) 'toolArgs': toolArgs,
        if (vmServicePort != null) 'vmServicePort': vmServicePort,
        if (console != null) 'console': console,
        if (enableAsserts != null) 'enableAsserts': enableAsserts,
      };

  static DartLaunchRequestArguments fromJson(Map<String, Object?> obj) =>
      DartLaunchRequestArguments.fromMap(obj);
}
