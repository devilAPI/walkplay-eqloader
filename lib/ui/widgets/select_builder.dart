import 'package:flutter/widgets.dart';

/// Like [ListenableBuilder], but rebuilds only when [select]'s value changes
/// rather than on every notification.
class SelectBuilder<T> extends StatefulWidget {
  final Listenable listenable;
  final T Function() select;
  final WidgetBuilder builder;
  const SelectBuilder(this.listenable, this.select, this.builder, {super.key});

  @override
  State<SelectBuilder<T>> createState() => _SelectBuilderState<T>();
}

class _SelectBuilderState<T> extends State<SelectBuilder<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.select();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(SelectBuilder<T> old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _value = widget.select();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final value = widget.select();
    if (value != _value) setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
