import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/suggestions_controller.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/suggestions_decoration.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/suggestions_list_animation.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/suggestions_list_config.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/suggestions_list_keyboard_connector.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/suggestions_list_text_connector.dart';
import 'package:flutter_typeahead/src/common/suggestions_box/typedef.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// Renders all the suggestions using a ListView as default.
/// If `layoutArchitecture` is specified, uses that instead.
abstract class BaseSuggestionsList<T> extends StatefulWidget
    implements SuggestionsListConfig<T> {
  const BaseSuggestionsList({
    super.key,
    this.animationDuration,
    this.animationStart,
    this.autoFlipListDirection = true,
    required this.controller,
    this.debounceDuration,
    this.direction = AxisDirection.down,
    this.errorBuilder,
    this.hideKeyboardOnDrag = false,
    this.hideOnEmpty,
    this.hideOnError,
    this.hideOnLoading,
    this.hideOnSelect,
    required this.itemBuilder,
    this.itemSeparatorBuilder,
    this.keepSuggestionsOnLoading,
    this.layoutArchitecture,
    this.loadingBuilder,
    this.minCharsForSuggestions,
    this.noItemsFoundBuilder,
    this.onSuggestionSelected,
    this.scrollController,
    required this.suggestionsController,
    this.suggestionsCallback,
    this.transitionBuilder,
  });

  @override
  final Duration? animationDuration;
  @override
  final double? animationStart;
  @override
  final bool autoFlipListDirection;
  @override
  final TextEditingController controller;
  @override
  final Duration? debounceDuration;
  @override
  final AxisDirection direction;
  @override
  final ErrorBuilder? errorBuilder;
  @override
  final bool hideKeyboardOnDrag;
  @override
  final bool? hideOnEmpty;
  @override
  final bool? hideOnError;
  @override
  final bool? hideOnSelect;
  @override
  final bool? hideOnLoading;
  @override
  final ItemBuilder<T> itemBuilder;
  @override
  final IndexedWidgetBuilder? itemSeparatorBuilder;
  @override
  final bool? keepSuggestionsOnLoading;
  @override
  final LayoutArchitecture? layoutArchitecture;
  @override
  final WidgetBuilder? loadingBuilder;
  @override
  final int? minCharsForSuggestions;
  @override
  final WidgetBuilder? noItemsFoundBuilder;
  @override
  final SuggestionSelectionCallback<T>? onSuggestionSelected;
  @override
  final ScrollController? scrollController;
  @override
  final SuggestionsController suggestionsController;
  @override
  final SuggestionsCallback<T>? suggestionsCallback;
  @override
  final AnimationTransitionBuilder? transitionBuilder;

  BaseSuggestionsDecoration? get decoration;

  /// Creates a widget to display while suggestions are loading.
  @protected
  Widget createLoadingWidget(
    BuildContext context,
    SuggestionsListState<T> state,
  );

  /// Creates a widget to display when an error has occurred.
  @protected
  Widget createErrorWidget(
    BuildContext context,
    SuggestionsListState<T> state,
  );

  /// Creates a widget to display when no suggestions are available.
  @protected
  Widget createNoItemsFoundWidget(
    BuildContext context,
    SuggestionsListState<T> state,
  );

  /// Creates a widget to display the suggestions.
  @protected
  Widget createSuggestionsWidget(
    BuildContext context,
    SuggestionsListState<T> state,
  );

  /// Creates a widget to wrap all the other widgets.
  @protected
  Widget createWidgetWrapper(
    BuildContext context,
    SuggestionsListState<T> state,
    Widget child,
  ) =>
      child;

  /// Call to select a suggestion.
  ///
  /// Handles closing the suggestions box if [hideOnSelect] is false.
  @protected
  void onSelected(T suggestion) {
    // We call this before closing the suggestions list
    // so that the text field can be updated without reopening the suggestions list.
    onSuggestionSelected?.call(suggestion);
    if (hideOnSelect ?? true) {
      suggestionsController.close(retainFocus: true);
    } else {
      suggestionsController.focusChild();
    }
  }

  @protected
  Widget createDefaultLayout(
    Iterable<Widget> items,
    ScrollController controller,
  ) {
    return ListView.separated(
      padding: EdgeInsets.zero,
      primary: false,
      shrinkWrap: true,
      keyboardDismissBehavior: hideKeyboardOnDrag
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
      controller: controller,
      reverse: direction == AxisDirection.up ? autoFlipListDirection : false,
      itemCount: items.length,
      itemBuilder: (context, index) => items.elementAt(index),
      separatorBuilder: (context, index) =>
          itemSeparatorBuilder?.call(context, index) ?? const SizedBox.shrink(),
    );
  }

  @override
  State<BaseSuggestionsList<T>> createState() => _BaseSuggestionsListState<T>();
}

class _BaseSuggestionsListState<T> extends State<BaseSuggestionsList<T>> {
  late final ScrollController _scrollController =
      widget.scrollController ?? ScrollController();

  bool isLoading = false;
  bool isQueued = false;
  String? lastTextValue;
  Iterable<T>? suggestions;
  Timer? debounceTimer;
  Object? error;

  @override
  void initState() {
    super.initState();

    lastTextValue = widget.controller.text;

    onOpenChange();
    widget.suggestionsController.addListener(onOpenChange);

    widget.controller.addListener(onTextChange);
  }

  @override
  void didUpdateWidget(BaseSuggestionsList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(onTextChange);
      widget.controller.addListener(onTextChange);
      onTextChange();
    }
  }

  @override
  void dispose() {
    debounceTimer?.cancel();
    widget.controller.removeListener(onTextChange);
    super.dispose();
  }

  void onOpenChange() {
    if (widget.suggestionsController.isOpen) {
      loadSuggestions();
    }
  }

  void onTextChange() {
    // ignore changes in selection only
    if (widget.controller.text == lastTextValue) return;
    lastTextValue = widget.controller.text;

    Duration? debounceDuration = widget.debounceDuration;
    debounceDuration ??= const Duration(milliseconds: 300);

    debounceTimer?.cancel();
    if (debounceDuration == Duration.zero) {
      reloadSuggestions();
    } else {
      debounceTimer = Timer(debounceDuration, () async {
        if (isLoading) {
          isQueued = true;
          return;
        }

        await reloadSuggestions();
        if (isQueued) {
          isQueued = false;
          await reloadSuggestions();
        }
      });
    }
  }

  Future<void> reloadSuggestions() async {
    suggestions = null;
    await loadSuggestions();
  }

  Future<void> loadSuggestions() async {
    if (!mounted) return;
    if (suggestions != null) return;

    setState(() {
      isLoading = true;
      error = null;
    });

    try {
      bool hasCharacters =
          widget.controller.text.length >= widget.minCharsForSuggestions!;
      if (hasCharacters) {
        suggestions = await widget.suggestionsCallback!(widget.controller.text);
      } else {
        suggestions = null;
      }
    } on Exception catch (e) {
      error = e;
    }

    if (!mounted) return;

    setState(() {
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    SuggestionsListState<T> state = SuggestionsListState<T>(
      scrollController: _scrollController,
      suggestions: suggestions,
      error: error,
    );

    bool keepSuggestionsOnLoading = widget.keepSuggestionsOnLoading ?? true;
    bool showLoading = keepSuggestionsOnLoading || suggestions == null;

    Widget child;
    if (isLoading && showLoading) {
      if (widget.hideOnLoading!) {
        child = const SizedBox();
      } else {
        child = widget.createLoadingWidget(context, state);
      }
    } else if (error != null) {
      if (widget.hideOnError!) {
        child = const SizedBox();
      } else {
        child = widget.createErrorWidget(context, state);
      }
    } else if (suggestions?.isEmpty ?? true) {
      if (widget.hideOnEmpty ?? false) {
        child = const SizedBox();
      } else {
        child = widget.createNoItemsFoundWidget(context, state);
      }
    } else {
      child = widget.createSuggestionsWidget(context, state);
    }

    return SuggestionsListKeyboardConnector(
      controller: widget.suggestionsController,
      child: SuggestionsListTextConnector(
        controller: widget.suggestionsController,
        textEditingController: widget.controller,
        child: PointerInterceptor(
          child: widget.createWidgetWrapper(
            context,
            state,
            SuggestionsListAnimation(
              controller: widget.suggestionsController,
              transitionBuilder: widget.transitionBuilder,
              direction: widget.direction,
              animationStart: widget.animationStart,
              animationDuration: widget.animationDuration,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class SuggestionsListState<T> {
  SuggestionsListState({
    required this.scrollController,
    this.suggestions,
    this.error,
  });

  final ScrollController scrollController;
  final Iterable<T>? suggestions;
  final Object? error;
}
