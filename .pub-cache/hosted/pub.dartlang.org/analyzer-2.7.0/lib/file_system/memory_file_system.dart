// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/source/source_resource.dart';
import 'package:path/path.dart' as pathos;
import 'package:watcher/watcher.dart';

/// An in-memory implementation of [ResourceProvider].
/// Use `/` as a path separator.
class MemoryResourceProvider implements ResourceProvider {
  final Map<String, _ResourceData> _pathToData = {};
  final Map<String, String> _pathToLinkedPath = {};
  final Map<String, List<StreamController<WatchEvent>>> _pathToWatchers = {};
  int nextStamp = 0;

  final pathos.Context _pathContext;

  MemoryResourceProvider(
      {pathos.Context? context, @deprecated bool isWindows = false})
      : _pathContext = context ??= pathos.style == pathos.Style.windows
            // On Windows, ensure that the current drive matches
            // the drive inserted by MemoryResourceProvider.convertPath
            // so that packages are mapped to the correct drive
            ? pathos.Context(current: 'C:\\')
            : pathos.context;

  @override
  pathos.Context get pathContext => _pathContext;

  /// Convert the given posix [path] to conform to this provider's path context.
  ///
  /// This is a utility method for testing; paths passed in to other methods in
  /// this class are never converted automatically.
  String convertPath(String path) {
    if (pathContext.style == pathos.windows.style) {
      if (path.startsWith(pathos.posix.separator)) {
        path = r'C:' + path;
      }
      path = path.replaceAll(pathos.posix.separator, pathos.windows.separator);
    }
    return path;
  }

  /// Delete the file with the given path.
  void deleteFile(String path) {
    var data = _pathToData[path];
    if (data is! _FileData) {
      throw FileSystemException(path, 'Not a file.');
    }

    _pathToData.remove(path);
    _removeFromParentFolderData(path);

    _notifyWatchers(path, ChangeType.REMOVE);
  }

  /// Delete the folder with the given path
  /// and recursively delete nested files and folders.
  void deleteFolder(String path) {
    var data = _pathToData[path];
    if (data is! _FolderData) {
      throw FileSystemException(path, 'Not a folder.');
    }

    for (var childName in data.childNames.toList()) {
      var childPath = pathContext.join(path, childName);
      var child = getResource(childPath);
      if (child is File) {
        deleteFile(child.path);
      } else if (child is Folder) {
        deleteFolder(child.path);
      } else {
        throw 'failed to delete resource: $child';
      }
    }

    if (_pathToData[path] != data) {
      throw StateError('Unexpected concurrent modification: $path');
    }
    if (data.childNames.isNotEmpty) {
      throw StateError('Must be empty.');
    }

    _pathToData.remove(path);
    _removeFromParentFolderData(path);

    _notifyWatchers(path, ChangeType.REMOVE);
  }

  @override
  File getFile(String path) {
    _ensureAbsoluteAndNormalized(path);
    return _MemoryFile(this, path);
  }

  @override
  Folder getFolder(String path) {
    _ensureAbsoluteAndNormalized(path);
    return _MemoryFolder(this, path);
  }

  @Deprecated('Not used by clients')
  @override
  Future<List<int>> getModificationTimes(List<Source> sources) async {
    return sources.map((source) {
      String path = source.fullName;
      var file = getFile(path);
      try {
        return file.modificationStamp;
      } on FileSystemException {
        return -1;
      }
    }).toList();
  }

  @override
  Resource getResource(String path) {
    _ensureAbsoluteAndNormalized(path);
    var data = _pathToData[path];
    return data is _FolderData
        ? _MemoryFolder(this, path)
        : _MemoryFile(this, path);
  }

  @override
  Folder getStateLocation(String pluginId) {
    var path = convertPath('/user/home/$pluginId');
    return newFolder(path);
  }

  void modifyFile(String path, String content) {
    var data = _pathToData[path];
    if (data is! _FileData) {
      throw FileSystemException(path, 'Not a file.');
    }

    _pathToData[path] = _FileData(
      bytes: utf8.encode(content) as Uint8List,
      timeStamp: nextStamp++,
    );
    _notifyWatchers(path, ChangeType.MODIFY);
  }

  /// Create a resource representing a dummy link (that is, a File object which
  /// appears in its parent directory, but whose `exists` property is false)
  @Deprecated('Not used by clients')
  File newDummyLink(String path) {
    _ensureAbsoluteAndNormalized(path);
    newFolder(pathContext.dirname(path));
    _MemoryDummyLink link = _MemoryDummyLink(this, path);
    _notifyWatchers(path, ChangeType.ADD);
    return link;
  }

  File newFile(
    String path,
    String content, [
    @Deprecated('This parameter is not used and will be removed') int? stamp,
  ]) {
    var bytes = utf8.encode(content) as Uint8List;
    // ignore: deprecated_member_use_from_same_package
    return newFileWithBytes(path, bytes, stamp);
  }

  File newFileWithBytes(
    String path,
    List<int> bytes, [
    @Deprecated('This parameter is not used and will be removed') int? stamp,
  ]) {
    _ensureAbsoluteAndNormalized(path);
    bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    var parentPath = pathContext.dirname(path);
    var parentData = _newFolder(parentPath);
    _addToParentFolderData(parentData, path);

    _pathToData[path] = _FileData(
      bytes: bytes,
      timeStamp: nextStamp++,
    );
    _notifyWatchers(path, ChangeType.ADD);

    return _MemoryFile(this, path);
  }

  Folder newFolder(String path) {
    _newFolder(path);
    return _MemoryFolder(this, path);
  }

  /// Create a link from the [path] to the [target].
  void newLink(String path, String target) {
    _ensureAbsoluteAndNormalized(path);
    _ensureAbsoluteAndNormalized(target);
    _pathToLinkedPath[path] = target;
  }

  @Deprecated('Not used by clients')
  File updateFile(String path, String content, [int? stamp]) {
    _ensureAbsoluteAndNormalized(path);
    newFolder(pathContext.dirname(path));
    _pathToData[path] = _FileData(
      bytes: utf8.encode(content) as Uint8List,
      timeStamp: stamp ?? nextStamp++,
    );
    _notifyWatchers(path, ChangeType.MODIFY);
    return _MemoryFile(this, path);
  }

  /// Write a representation of the file system on the given [sink].
  void writeOn(StringSink sink) {
    List<String> paths = _pathToData.keys.toList();
    paths.sort();
    paths.forEach(sink.writeln);
  }

  void _addToParentFolderData(_FolderData parentData, String path) {
    var childName = pathContext.basename(path);
    if (!parentData.childNames.contains(childName)) {
      parentData.childNames.add(childName);
    }
  }

  /// The file system abstraction supports only absolute and normalized paths.
  /// This method is used to validate any input paths to prevent errors later.
  void _ensureAbsoluteAndNormalized(String path) {
    if (!pathContext.isAbsolute(path)) {
      throw ArgumentError("Path must be absolute : $path");
    }
    if (pathContext.normalize(path) != path) {
      throw ArgumentError("Path must be normalized : $path");
    }
  }

  _FolderData _newFolder(String path) {
    _ensureAbsoluteAndNormalized(path);

    var data = _pathToData[path];
    if (data is _FolderData) {
      return data;
    } else if (data == null) {
      var parentPath = pathContext.dirname(path);
      if (parentPath != path) {
        var parentData = _newFolder(parentPath);
        _addToParentFolderData(parentData, path);
      }
      var data = _FolderData();
      _pathToData[path] = data;
      _notifyWatchers(path, ChangeType.ADD);
      return data;
    } else {
      throw FileSystemException(path, 'Folder expected.');
    }
  }

  void _notifyWatchers(String path, ChangeType changeType) {
    _pathToWatchers.forEach((String watcherPath,
        List<StreamController<WatchEvent>> streamControllers) {
      if (watcherPath == path || pathContext.isWithin(watcherPath, path)) {
        for (StreamController<WatchEvent> streamController
            in streamControllers) {
          streamController.add(WatchEvent(changeType, path));
        }
      }
    });
  }

  void _removeFromParentFolderData(String path) {
    var parentPath = pathContext.dirname(path);
    var parentData = _pathToData[parentPath] as _FolderData;
    var childName = pathContext.basename(path);
    parentData.childNames.remove(childName);
  }

  void _renameFileSync(String path, String newPath) {
    var data = _pathToData[path];
    if (data is! _FileData) {
      throw FileSystemException(path, 'Not a file.');
    }

    if (newPath == path) {
      return;
    }

    var existingNewData = _pathToData[newPath];
    if (existingNewData == null) {
      // Nothing to do.
    } else if (existingNewData is _FileData) {
      deleteFile(newPath);
    } else {
      throw FileSystemException(newPath, 'Not a file.');
    }

    var parentPath = pathContext.dirname(path);
    var parentData = _newFolder(parentPath);
    _addToParentFolderData(parentData, path);

    _pathToData.remove(path);
    _pathToData[newPath] = data;

    _notifyWatchers(path, ChangeType.REMOVE);
    _notifyWatchers(newPath, ChangeType.ADD);
  }

  String _resolveLinks(String path) {
    var parentPath = _pathContext.dirname(path);
    if (parentPath == path) {
      return path;
    }

    var canonicalParentPath = _resolveLinks(parentPath);

    var baseName = _pathContext.basename(path);
    var result = _pathContext.join(canonicalParentPath, baseName);

    do {
      var linkTarget = _pathToLinkedPath[result];
      if (linkTarget != null) {
        result = linkTarget;
      } else {
        break;
      }
    } while (true);

    return result;
  }

  void _setFileContent(String path, Uint8List bytes) {
    var parentPath = pathContext.dirname(path);
    var parentData = _newFolder(parentPath);
    _addToParentFolderData(parentData, path);

    _pathToData[path] = _FileData(
      bytes: bytes,
      timeStamp: nextStamp++,
    );
    _notifyWatchers(path, ChangeType.MODIFY);
  }
}

class _FileData extends _ResourceData {
  final Uint8List bytes;
  final int timeStamp;

  _FileData({
    required this.bytes,
    required this.timeStamp,
  });
}

class _FolderData extends _ResourceData {
  /// Names (not paths) of direct children.
  final List<String> childNames = [];
}

/// An in-memory implementation of [File] which acts like a symbolic link to a
/// non-existent file.
class _MemoryDummyLink extends _MemoryResource implements File {
  _MemoryDummyLink(MemoryResourceProvider provider, String path)
      : super(provider, path);

  @override
  Stream<WatchEvent> get changes {
    throw FileSystemException(path, "File does not exist");
  }

  @override
  bool get exists => false;

  @override
  int get lengthSync {
    throw FileSystemException(path, 'File could not be read');
  }

  @override
  int get modificationStamp {
    throw FileSystemException(path, "File does not exist");
  }

  @override
  File copyTo(Folder parentFolder) {
    throw FileSystemException(path, 'File could not be copied');
  }

  @override
  Source createSource([Uri? uri]) {
    throw FileSystemException(path, 'File could not be read');
  }

  @override
  void delete() {
    throw FileSystemException(path, 'File could not be deleted');
  }

  @override
  bool isOrContains(String path) {
    return path == this.path;
  }

  @override
  Uint8List readAsBytesSync() {
    throw FileSystemException(path, 'File could not be read');
  }

  @override
  String readAsStringSync() {
    throw FileSystemException(path, 'File could not be read');
  }

  @override
  File renameSync(String newPath) {
    throw FileSystemException(path, 'File could not be renamed');
  }

  @override
  File resolveSymbolicLinksSync() {
    return throw FileSystemException(path, "File does not exist");
  }

  @override
  void writeAsBytesSync(List<int> bytes) {
    throw FileSystemException(path, 'File could not be written');
  }

  @override
  void writeAsStringSync(String content) {
    throw FileSystemException(path, 'File could not be written');
  }
}

/// An in-memory implementation of [File].
class _MemoryFile extends _MemoryResource implements File {
  _MemoryFile(MemoryResourceProvider provider, String path)
      : super(provider, path);

  @override
  bool get exists {
    var canonicalPath = provider._resolveLinks(path);
    return provider._pathToData[canonicalPath] is _FileData;
  }

  @override
  int get lengthSync {
    return readAsBytesSync().length;
  }

  @override
  int get modificationStamp {
    var canonicalPath = provider._resolveLinks(path);
    var data = provider._pathToData[canonicalPath];
    if (data is! _FileData) {
      throw FileSystemException(path, 'File does not exist.');
    }
    return data.timeStamp;
  }

  @override
  File copyTo(Folder parentFolder) {
    parentFolder.create();
    File destination = parentFolder.getChildAssumingFile(shortName);
    destination.writeAsBytesSync(readAsBytesSync());
    return destination;
  }

  @override
  Source createSource([Uri? uri]) {
    uri ??= provider.pathContext.toUri(path);
    return FileSource(this, uri);
  }

  @override
  void delete() {
    provider.deleteFile(path);
  }

  @override
  bool isOrContains(String path) {
    return path == this.path;
  }

  @override
  Uint8List readAsBytesSync() {
    var canonicalPath = provider._resolveLinks(path);
    var data = provider._pathToData[canonicalPath];
    if (data is! _FileData) {
      throw FileSystemException(path, 'File does not exist.');
    }
    return data.bytes;
  }

  @override
  String readAsStringSync() {
    var bytes = readAsBytesSync();
    return utf8.decode(bytes);
  }

  @override
  File renameSync(String newPath) {
    provider._renameFileSync(path, newPath);
    return provider.getFile(newPath);
  }

  @override
  File resolveSymbolicLinksSync() {
    var canonicalPath = provider._resolveLinks(path);
    var result = provider.getFile(canonicalPath);

    if (!result.exists) {
      throw FileSystemException(path, 'File does not exist.');
    }

    return result;
  }

  @override
  void writeAsBytesSync(List<int> bytes) {
    bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    provider._setFileContent(path, bytes);
  }

  @override
  void writeAsStringSync(String content) {
    var bytes = utf8.encode(content) as Uint8List;
    writeAsBytesSync(bytes);
  }
}

/// An in-memory implementation of [Folder].
class _MemoryFolder extends _MemoryResource implements Folder {
  _MemoryFolder(MemoryResourceProvider provider, String path)
      : super(provider, path);

  @override
  bool get exists {
    var canonicalPath = provider._resolveLinks(path);
    return provider._pathToData[canonicalPath] is _FolderData;
  }

  @override
  bool get isRoot {
    var parentPath = provider.pathContext.dirname(path);
    return parentPath == path;
  }

  @override
  String canonicalizePath(String relPath) {
    relPath = provider.pathContext.normalize(relPath);
    String childPath = provider.pathContext.join(path, relPath);
    childPath = provider.pathContext.normalize(childPath);
    return childPath;
  }

  @override
  bool contains(String path) {
    return provider.pathContext.isWithin(this.path, path);
  }

  @override
  Folder copyTo(Folder parentFolder) {
    Folder destination = parentFolder.getChildAssumingFolder(shortName);
    destination.create();
    for (Resource child in getChildren()) {
      child.copyTo(destination);
    }
    return destination;
  }

  @override
  void create() {
    provider.newFolder(path);
  }

  @override
  void delete() {
    provider.deleteFolder(path);
  }

  @override
  Resource getChild(String relPath) {
    var path = canonicalizePath(relPath);
    return provider.getResource(path);
  }

  @override
  _MemoryFile getChildAssumingFile(String relPath) {
    var path = canonicalizePath(relPath);
    return _MemoryFile(provider, path);
  }

  @override
  _MemoryFolder getChildAssumingFolder(String relPath) {
    var path = canonicalizePath(relPath);
    return _MemoryFolder(provider, path);
  }

  @override
  List<Resource> getChildren() {
    var canonicalPath = provider._resolveLinks(path);
    if (canonicalPath != path) {
      var target = provider.getFolder(canonicalPath);
      var canonicalChildren = target.getChildren();
      return canonicalChildren.map((child) {
        var childPath = provider.pathContext.join(path, child.shortName);
        if (child is Folder) {
          return _MemoryFolder(provider, childPath);
        } else {
          return _MemoryFile(provider, childPath);
        }
      }).toList();
    }

    var data = provider._pathToData[path];
    if (data is! _FolderData) {
      throw FileSystemException(path, 'Folder does not exist.');
    }

    var children = <Resource>[];
    for (var childName in data.childNames) {
      var childPath = provider.pathContext.join(path, childName);
      var child = provider.getResource(childPath);
      children.add(child);
    }

    provider._pathToLinkedPath.forEach((resourcePath, targetPath) {
      if (provider.pathContext.dirname(resourcePath) == path) {
        var target = provider.getResource(targetPath);
        if (target is File) {
          children.add(
            _MemoryFile(provider, resourcePath),
          );
        } else if (target is Folder) {
          children.add(
            _MemoryFolder(provider, resourcePath),
          );
        }
      }
    });

    return children;
  }

  @override
  bool isOrContains(String path) {
    if (path == this.path) {
      return true;
    }
    return contains(path);
  }

  @override
  Folder resolveSymbolicLinksSync() {
    var canonicalPath = provider._resolveLinks(path);
    var result = provider.getFolder(canonicalPath);

    if (!result.exists) {
      throw FileSystemException(path, 'Folder does not exist.');
    }

    return result;
  }

  @override
  Uri toUri() => provider.pathContext.toUri(path + '/');
}

/// An in-memory implementation of [Resource].
abstract class _MemoryResource implements Resource {
  @override
  final MemoryResourceProvider provider;

  @override
  final String path;

  _MemoryResource(this.provider, this.path);

  Stream<WatchEvent> get changes {
    StreamController<WatchEvent> streamController =
        StreamController<WatchEvent>();
    if (!provider._pathToWatchers.containsKey(path)) {
      provider._pathToWatchers[path] = <StreamController<WatchEvent>>[];
    }
    provider._pathToWatchers[path]!.add(streamController);
    streamController.done.then((_) {
      provider._pathToWatchers[path]!.remove(streamController);
      if (provider._pathToWatchers[path]!.isEmpty) {
        provider._pathToWatchers.remove(path);
      }
    });
    return streamController.stream;
  }

  @override
  int get hashCode => path.hashCode;

  @Deprecated('Use parent2 instead')
  @override
  Folder? get parent {
    String parentPath = provider.pathContext.dirname(path);
    if (parentPath == path) {
      return null;
    }
    return provider.getFolder(parentPath);
  }

  @override
  Folder get parent2 {
    String parentPath = provider.pathContext.dirname(path);
    return provider.getFolder(parentPath);
  }

  @override
  String get shortName => provider.pathContext.basename(path);

  @override
  bool operator ==(Object other) {
    if (runtimeType != other.runtimeType) {
      return false;
    }
    return path == (other as _MemoryResource).path;
  }

  @override
  String toString() => path;

  @override
  Uri toUri() => provider.pathContext.toUri(path);
}

class _ResourceData {}