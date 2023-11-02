library blocx;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:obx/obx.dart';

export 'package:obx/obx.dart';

typedef Response<T, E> = FutureOr<Result<T, E>>;

typedef EmptyResult = Result<void, void>;
typedef EmptyResponse = FutureOr<EmptyResult>;

sealed class Result<T, E> {}

abstract class RxAction<S extends RxStore, T> {
  @nonVirtual
  T dispatch([S? store]) =>
      (store ??= locate<S>())._reducer.dispatch(this, store);
}

abstract class Reducer<S extends RxStore> {
  R dispatch<T extends RxAction<S, R>, R>(T action, S store);
}

abstract class RxStore {
  late final Reducer _reducer = createReducer();
  Reducer createReducer();
}

final class Ok<T, E> extends Result<T, E> {
  T data;
  Ok(this.data);
}

final class Err<T, E> extends Result<T, E> {
  E err;
  Err(this.err);
}

class DuplicateEventHandlerException implements Exception {
  final String message;
  DuplicateEventHandlerException(this.message);
}

class UnreachableActionException implements Exception {
  final RxAction action;

  UnreachableActionException(this.action);

  @override
  String toString() =>
      '$runtimeType(Recieved an illegal Action of type: ${action.runtimeType})';
}

typedef StateEmitter<S> = void Function(S);

typedef EventHandler<E extends Event, S extends Object> = void Function(
  E event,
  StateEmitter<S> emit,
);

@immutable
class Event extends Notification {
  const Event();

  @override
  // ignore: avoid_renaming_method_parameters
  void dispatch(BuildContext? context) {
    super.dispatch(context);
  }
}

class Observer<T, S extends Object> {
  T Function() observer;
  Function(T, StateEmitter<S>) handler;

  Observer(this.observer, this.handler);
}

abstract class Bloc<E extends Event, S extends Object> {
  Rx<E> createEvent() => Rx<E>.indistinct();
  late final _eventChannel = createEvent();
  final _childEventChannels = <Rx<E>>[];

  S get initialState;
  Rx<S> createState(S initialState) => Rx<S>(initialState);
  late final _stateChannel = createState(initialState);
  S get state => _stateChannel.data;

  final List<Rx> _dependencies = [];

  @protected
  @nonVirtual
  void watch<T>(T Function() observer, Function(T, StateEmitter<S>) handler) {
    _dependencies.add(Rx.fuse(observer)
      ..listen((value) => handler(value, _stateChannel.add)));
  }

  @mustCallSuper
  void dispose() {
    _eventChannel.close();
    for (final e in _childEventChannels) {
      e.close();
    }
    _stateChannel.close();
    for (final e in _dependencies) {
      e.close();
    }
  }

  @protected
  @nonVirtual
  void on<T extends E>(EventHandler<T, S> handler,
      {RxTransformer<T>? transformer}) {
    assert(() {
      if (_childEventChannels.any((e) => e is Rx<T>)) {
        throw DuplicateEventHandlerException(
            'on<$T> was called multiple times. '
            'Duplicate registration for event handler of type $T');
      }
      return true;
    }());
    _childEventChannels.add(_eventChannel.pipe<T>((e) =>
        transformer == null ? e.whereType<T>() : transformer(e.whereType<T>()))
      ..listen((v) => handler(v, _stateChannel.add)));
  }
}

class InheritedState<S extends Object> extends InheritedWidget {
  final Rx<S> _stateChannel;
  const InheritedState(
      {super.key, required super.child, required Rx<S> stateChannel})
      : _stateChannel = stateChannel,
        super();

  @override
  bool updateShouldNotify(covariant InheritedState<S> oldWidget) =>
      oldWidget._stateChannel.data != _stateChannel.data;
}

class BlocAdapter<E extends Event, S extends Object> extends StatefulWidget {
  final Bloc<E, S> Function(BuildContext) create;
  final Widget child;

  const BlocAdapter({super.key, required this.create, required this.child});

  BlocAdapter.builder(
      {super.key,
      required this.create,
      required Widget Function(BuildContext context) builder})
      : child = Builder(builder: builder);

  BlocAdapter.consumer(
      {super.key,
      required this.create,
      required Widget Function(BuildContext context, S state) builder})
      : child = Consumer(builder);

  @override
  State<BlocAdapter<E, S>> createState() => _BlocAdapterState<E, S>();
}

class _BlocAdapterState<E extends Event, S extends Object>
    extends State<BlocAdapter<E, S>> {
  late final Bloc<E, S> bloc = widget.create(context);

  bool _handle(E e) {
    bloc._eventChannel.data = e;
    return true;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<E>(
        onNotification: _handle,
        child: InheritedState<S>(
          stateChannel: bloc._stateChannel,
          child: widget.child,
        ),
      );
}

class Consumer<S extends Object> extends Widget {
  final Widget Function(BuildContext context, S state) builder;
  const Consumer(this.builder, {super.key});

  @override
  InheritedStateElement<S> createElement() => InheritedStateElement<S>(this);
}

class InheritedStateElement<S extends Object> extends ComponentElement {
  S? state;
  RxSubscription<S>? _sub;

  InheritedStateElement(super.widget);

  @override
  void attachNotificationTree() {
    super.attachNotificationTree();
    final channel =
        dependOnInheritedWidgetOfExactType<InheritedState<S>>()!._stateChannel;
    state = channel.data;
    _sub?.syncCancel();
    _sub = channel.listen((value) {
      state = value;
      markNeedsBuild();
    });
  }

  @override
  void unmount() {
    super.unmount();
    _sub?.syncCancel();
    state = null;
  }

  @override
  Widget build() => (widget as Consumer<S>).builder(this, state!);
}

class _TypeKey<T> {
  final dynamic key;
  Type get type => T;

  _TypeKey([this.key]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TypeKey && type == other.type && key == other.key;

  @override
  int get hashCode => key.hashCode;
}

class Factory<T> {
  static final Map<_TypeKey, Factory> _factories = {};

  T? _instance;
  T Function()? _builder;

  // Private internal constructor.
  Factory._internal(this._builder);

  T Function() get builder =>
      _builder ?? (throw StateError('No builder provided for type $T'));

  T find() => _instance ??= builder();
  factory Factory._({T Function()? builder, dynamic tag}) =>
      switch ((Factory._factories[_TypeKey<T>(tag)], builder)) {
        (null, _) => Factory._factories[_TypeKey<T>(tag)] =
            Factory<T>._internal(builder),
        (final Factory<T> factory, null) => factory,
        (final Factory<T> factory, T Function() builder) => factory
          .._builder = builder,
        _ => throw "Unreachable condition",
      };
}

T inject<T>(T Function() builder, [dynamic tag]) =>
    Factory<T>._(builder: builder, tag: tag).find();
Factory<T> lazy<T>(T Function() builder, [dynamic tag]) =>
    Factory<T>._(builder: builder, tag: tag);
T locate<T>([dynamic tag]) => Factory<T>._(tag: tag).find();
