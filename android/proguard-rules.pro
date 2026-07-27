# SmoothClipView is resolved from C++ by name (fbjni findClassStatic) and its
# setClipPresentationDip / setClipPresentationPx are invoked through cached
# jmethodIDs; SmoothClipBindings registers native methods by name. None of them
# may be renamed or stripped in consumer release builds.
-keep class com.smoothclipview.SmoothClipView { *; }
-keep class com.smoothclipview.SmoothClipBindings { *; }
