package com.smoothclipview

import com.facebook.react.bridge.ReadableArray
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.ViewProps
import com.facebook.react.views.view.ReactViewGroup
import com.facebook.react.views.view.ReactViewManager

/**
 * Applies the `View` props a codegen delegate drops, through a `<View>`'s own
 * setters: `pointerEvents`, the border props (radius, width, color, style)
 * and, unless the view owns its clip, `overflow`. `BaseViewManagerDelegate`
 * routes only the physical radii, cast to numbers (a percent radius threw),
 * to setters that just log "unsupported", and never routes the rest; iOS
 * applies them all.
 *
 * React Native 0.88's ViewManagerDelegate names its Kotlin members
 * `kotlinCompat$setProperty` / `kotlinCompat$receiveCommand` on the JVM and
 * gives its Java-compat defaults the plain names. Overrides compiled under
 * the plain names collide with the compat stubs Kotlin emits in this class:
 * the class file holds two identical methods and fails to load
 * (ClassFormatError), taking the view managers down with it. The overrides
 * therefore carry the interface's JVM names.
 */
internal class ViewPropsDelegate<T : ReactViewGroup>(
    private val inner: ViewManagerDelegate<T>,
    /** False for a view that owns its clip: `overflow` stays unapplied. */
    private val overflow: Boolean = true,
) : ViewManagerDelegate<T> {
    @Suppress("INAPPLICABLE_JVM_NAME")
    @JvmName("kotlinCompat\$setProperty")
    override fun setProperty(view: T, propName: String, value: Any?) {
        if (propName == ViewProps.POINTER_EVENTS || propName.startsWith("border") ||
            overflow && propName == ViewProps.OVERFLOW
        ) {
            ViewSetters.setters.setProperty(view, propName, value)
        } else {
            inner.setProperty(view, propName, value)
        }
    }

    @Suppress("INAPPLICABLE_JVM_NAME")
    @JvmName("kotlinCompat\$receiveCommand")
    override fun receiveCommand(view: T, commandName: String, args: ReadableArray) =
        inner.receiveCommand(view, commandName, args)

    /**
     * ReactViewManager's default delegate: only a `<View>`'s setters, not its
     * end-of-transaction work.
     */
    private object ViewSetters : ReactViewManager() {
        // Not `delegate`: its getter would clash with ViewManager.getDelegate().
        val setters: ViewManagerDelegate<ReactViewGroup> = getDelegate()
    }
}
