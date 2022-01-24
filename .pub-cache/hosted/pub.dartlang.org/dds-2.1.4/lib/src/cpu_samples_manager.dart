// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dds/src/common/ring_buffer.dart';
import 'package:vm_service/vm_service.dart';

import 'dds_impl.dart';

/// Manages CPU sample caches for an individual [Isolate].
class CpuSamplesManager {
  CpuSamplesManager(this.dds, this.isolateId) {
    for (final userTag in dds.cachedUserTags) {
      cpuSamplesCaches[userTag] = CpuSamplesRepository(userTag);
    }
  }

  void handleUserTagEvent(Event event) {
    assert(event.kind! == EventKind.kUserTagChanged);
    _currentTag = event.updatedTag!;
    final previousTag = event.previousTag!;
    if (cpuSamplesCaches.containsKey(previousTag)) {
      _lastCachedTag = previousTag;
    }
  }

  void handleCpuSamplesEvent(Event event) {
    assert(event.kind! == EventKind.kCpuSamples);
    // There might be some samples left in the buffer for the previously set
    // user tag. We'll check for them here and then close out the cache.
    if (_lastCachedTag != null) {
      cpuSamplesCaches[_lastCachedTag]!.cacheSamples(
        event.cpuSamples!,
      );
      _lastCachedTag = null;
    }
    cpuSamplesCaches[_currentTag]?.cacheSamples(event.cpuSamples!);
  }

  final DartDevelopmentServiceImpl dds;
  final String isolateId;
  final cpuSamplesCaches = <String, CpuSamplesRepository>{};

  String _currentTag = '';
  String? _lastCachedTag;
}

class CpuSamplesRepository extends RingBuffer<CpuSample> {
  // TODO(#46978): math to figure out proper buffer sizes.
  CpuSamplesRepository(
    this.tag, [
    int bufferSize = 1000000,
  ]) : super(bufferSize);

  void cacheSamples(CpuSamples samples) {
    String getFunctionId(ProfileFunction function) {
      final functionObject = function.function;
      if (functionObject is NativeFunction) {
        return 'native/${functionObject.name}';
      }
      return functionObject.id!;
    }

    // Initialize upon seeing our first samples.
    if (functions.isEmpty) {
      samplePeriod = samples.samplePeriod!;
      maxStackDepth = samples.maxStackDepth!;
      pid = samples.pid!;
      functions.addAll(samples.functions!);

      // Build the initial id to function index mapping. This allows for us to
      // lookup a ProfileFunction in the global function list stored in this
      // cache. This works since most ProfileFunction objects will have an
      // associated function with a *typically* stable service ID that we can
      // use as a key.
      //
      // TODO(bkonyi): investigate creating some form of stable ID for
      // Functions tied to closures.
      for (int i = 0; i < functions.length; ++i) {
        idToFunctionIndex[getFunctionId(functions[i])] = i;
      }

      // Clear tick information as we'll need to recalculate these values later
      // when a request for samples from this repository is received.
      for (final f in functions) {
        f.inclusiveTicks = 0;
        f.exclusiveTicks = 0;
      }

      _firstSampleTimestamp = samples.timeOriginMicros!;
    } else {
      final newFunctions = samples.functions!;
      final indexMapping = <int, int>{};

      // Check to see if we've got a function object we've never seen before.
      for (int i = 0; i < newFunctions.length; ++i) {
        final key = getFunctionId(newFunctions[i]);
        if (!idToFunctionIndex.containsKey(key)) {
          idToFunctionIndex[key] = functions.length;
          // Keep track of the original index and the location of the function
          // in the master function list so we can update the function indicies
          // for each sample in this batch.
          indexMapping[i] = functions.length;
          functions.add(newFunctions[i]);

          // Reset tick state as we'll recalculate later.
          functions.last.inclusiveTicks = 0;
          functions.last.exclusiveTicks = 0;
        }
      }

      // Update the indicies into the function table for functions that were
      // newly processed in the most recent event.
      for (final sample in samples.samples!) {
        final stack = sample.stack!;
        for (int i = 0; i < stack.length; ++i) {
          if (indexMapping.containsKey(stack[i])) {
            stack[i] = indexMapping[stack[i]]!;
          }
        }
      }
    }

    final relevantSamples = samples.samples!.where((s) => s.userTag == tag);
    for (final sample in relevantSamples) {
      add(sample);
    }
  }

  @override
  CpuSample? add(CpuSample sample) {
    final evicted = super.add(sample);

    void updateTicksForSample(CpuSample sample, int increment) {
      final stack = sample.stack!;
      for (int i = 0; i < stack.length; ++i) {
        final function = functions[stack[i]];
        function.inclusiveTicks = function.inclusiveTicks! + increment;
        if (i + 1 == stack.length) {
          function.exclusiveTicks = function.exclusiveTicks! + increment;
        }
      }
    }

    if (evicted != null) {
      // If a sample is evicted from the cache, we need to decrement the tick
      // counters for each function in the sample's stack.
      updateTicksForSample(sample, -1);

      // We also need to change the first timestamp to that of the next oldest
      // sample.
      _firstSampleTimestamp = call().first.timestamp!;
    }
    _lastSampleTimestamp = sample.timestamp!;

    // Update function ticks to include the new sample.
    updateTicksForSample(sample, 1);

    return evicted;
  }

  Map<String, dynamic> toJson() {
    return {
      'type': 'CachedCpuSamples',
      'userTag': tag,
      'truncated': isTruncated,
      if (functions.isNotEmpty) ...{
        'samplePeriod': samplePeriod,
        'maxStackDepth': maxStackDepth,
      },
      'timeOriginMicros': _firstSampleTimestamp,
      'timeExtentMicros': _lastSampleTimestamp - _firstSampleTimestamp,
      'functions': [
        // TODO(bkonyi): remove functions with no ticks and update sample stacks.
        for (final f in functions) f.toJson(),
      ],
      'sampleCount': call().length,
      'samples': [
        for (final s in call()) s.toJson(),
      ]
    };
  }

  /// The UserTag associated with all samples stored in this repository.
  final String tag;

  /// The list of function references with corresponding profiler tick data.
  /// ** NOTE **: The tick values here need to be updated as new CpuSamples
  /// events are delivered.
  final functions = <ProfileFunction>[];
  final idToFunctionIndex = <String, int>{};

  /// Assume sample period and max stack depth won't change.
  late final int samplePeriod;
  late final int maxStackDepth;

  late final int pid;

  int _firstSampleTimestamp = 0;
  int _lastSampleTimestamp = 0;
}
