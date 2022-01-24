import 'dart:async';

import 'package:test/test.dart';

void main() {
  test('some_test', () async {
    Stream<S> mergeMap<S, T>(Stream<T> stream, Stream<S> Function(T) convert) {
      var controller = StreamController<S>();
      late StreamSubscription subscription;
      controller.onListen = () => subscription = stream.map((data) async* {
            print('Running async*');
            try {
              await for (var converted in convert(data).handleError((error) {
                print('Stream error handler: $error');
                throw error;
              })) {
                yield converted;
              }
            } catch (error) {
              print('Catch block: $error');
              rethrow;
            }
          }).listen((s) {
            s.listen(controller.add, onError: controller.addError);
          }, onError: controller.addError);
      controller.onCancel = () => subscription.cancel();

      return controller.stream;
    }

    final convertCompleter = Completer<void>();
    Stream<String> convert(String value) async* {
      await convertCompleter.future;
      yield value;
    }

    final source = StreamController<String>();

    mergeMap(source.stream, convert).listen((i) {
      print('Data: $i');
    }, onError: (e) {
      print('Error: $e');
    });
    source.add('a');
    await Future(() => Future(() => Future(() {})));
    print('Completing as error');
    convertCompleter.completeError(Exception('Intentional test failure'));
    await Future(() => Future(() => Future(() {})));
    print('Done');
  });
}
