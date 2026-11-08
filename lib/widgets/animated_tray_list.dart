import 'dart:math' as math;

import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/material.dart';

typedef TrayItemBuilder<T> = Widget Function(BuildContext context, T item);

/// A list of "trays" that animate in and out.
///
/// Give it the current [items] and a stable [keyOf]; on every rebuild it
/// diffs against the previous items. New keys slide up, fade and grow in;
/// removed keys collapse and fade out. Items whose key survives simply
/// rebuild in place (including reorders), so live data such as distances
/// updates without replaying the animation.
///
/// Use [sliver] = true inside a `CustomScrollView` (e.g. a draggable sheet).
class AnimatedTrayList<T> extends StatefulWidget {
  const AnimatedTrayList({
    super.key,
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    this.sliver = false,
    this.padding = EdgeInsets.zero,
    this.gap = EchoTheme.trayGap,
    this.insertDuration = EchoTheme.medium,
    this.removeDuration = EchoTheme.medium,
  });

  final List<T> items;
  final Object Function(T item) keyOf;
  final TrayItemBuilder<T> itemBuilder;
  final bool sliver;
  final EdgeInsetsGeometry padding;
  final double gap;
  final Duration insertDuration;
  final Duration removeDuration;

  @override
  State<AnimatedTrayList<T>> createState() => _AnimatedTrayListState<T>();
}

class _AnimatedTrayListState<T> extends State<AnimatedTrayList<T>> {
  final GlobalKey<AnimatedListState> _boxKey = GlobalKey<AnimatedListState>();
  final GlobalKey<SliverAnimatedListState> _sliverKey =
      GlobalKey<SliverAnimatedListState>();
  late List<T> _items;

  @override
  void initState() {
    super.initState();
    _items = List<T>.of(widget.items);
  }

  @override
  void didUpdateWidget(covariant AnimatedTrayList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync(widget.items);
  }

  void _sync(List<T> next) {
    final List<Object> nextKeys = next.map(widget.keyOf).toList();
    final Set<Object> nextKeySet = nextKeys.toSet();

    // 1. Removals, from the end so indices stay valid.
    for (int i = _items.length - 1; i >= 0; i--) {
      final T item = _items[i];
      if (!nextKeySet.contains(widget.keyOf(item))) {
        _items.removeAt(i);
        _removeAt(i, item);
      }
    }

    // 2. Insertions, at their target positions.
    final Map<Object, T> byKey = <Object, T>{
      for (final T t in next) widget.keyOf(t): t,
    };
    for (int i = 0; i < nextKeys.length; i++) {
      final Object k = nextKeys[i];
      if (_items.every((T t) => widget.keyOf(t) != k)) {
        final int at = math.min(i, _items.length);
        _items.insert(at, byKey[k] as T);
        _insertAt(at);
      }
    }

    // 3. Same length as the animated list now: adopt the new order/data.
    _items = List<T>.of(next);
  }

  void _insertAt(int index) {
    if (widget.sliver) {
      _sliverKey.currentState?.insertItem(
        index,
        duration: widget.insertDuration,
      );
    } else {
      _boxKey.currentState?.insertItem(index, duration: widget.insertDuration);
    }
  }

  void _removeAt(int index, T item) {
    Widget builder(BuildContext context, Animation<double> animation) =>
        _wrap(context, item, animation, removing: true);
    if (widget.sliver) {
      _sliverKey.currentState?.removeItem(
        index,
        builder,
        duration: widget.removeDuration,
      );
    } else {
      _boxKey.currentState?.removeItem(
        index,
        builder,
        duration: widget.removeDuration,
      );
    }
  }

  Widget _wrap(
    BuildContext context,
    T item,
    Animation<double> animation, {
    bool removing = false,
  }) {
    final Animation<double> curved = CurvedAnimation(
      parent: animation,
      curve: EchoTheme.enter,
      reverseCurve: EchoTheme.exit,
    );
    final Widget child = Padding(
      padding: EdgeInsets.only(bottom: widget.gap),
      child: widget.itemBuilder(context, item),
    );
    final Widget moving = FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, removing ? 0.15 : 0.35),
          end: Offset.zero,
        ).animate(curved),
        // A removed item must not react to taps while it collapses.
        child: removing ? IgnorePointer(child: child) : child,
      ),
    );
    // Grow/collapse from the top edge. Built from ClipRect + Align so it
    // behaves the same on every supported Flutter version.
    return AnimatedBuilder(
      animation: curved,
      child: moving,
      builder: (BuildContext context, Widget? c) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: curved.value.clamp(0.0, 1.0),
          child: c,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sliver) {
      return SliverPadding(
        padding: widget.padding,
        sliver: SliverAnimatedList(
          key: _sliverKey,
          initialItemCount: _items.length,
          itemBuilder: (BuildContext c, int i, Animation<double> a) =>
              _wrap(c, _items[i], a),
        ),
      );
    }
    return AnimatedList(
      key: _boxKey,
      shrinkWrap: true,
      primary: false,
      physics: const NeverScrollableScrollPhysics(),
      padding: widget.padding,
      initialItemCount: _items.length,
      itemBuilder: (BuildContext c, int i, Animation<double> a) =>
          _wrap(c, _items[i], a),
    );
  }
}
