package com.smoothclipview

import android.view.View
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.uimanager.PointerEvents
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.ViewProps
import com.facebook.react.views.view.ReactViewGroup

/**
 * Codegen delegates drop `pointerEvents` (only `ReactViewManager` applies it).
 *
 * React Native 0.88's ViewManagerDelegate names its Kotlin members
 * `kotlinCompat$setProperty` / `kotlinCompat$receiveCommand` on the JVM and
 * gives its Java-compat defaults the plain names. Overrides compiled under
 * the plain names collide with the compat stubs Kotlin emits in this class:
 * the class file holds two identical methods and fails to load
 * (ClassFormatError), taking the view managers down with it. The overrides
 * therefore carry the interface's JVM names.
 */
internal class PointerEventsDelegate<T : View>(
    private val codegen: ViewManagerDelegate<T>,
) : ViewManagerDelegate<T> {
    @Suppress("INAPPLICABLE_JVM_NAME")
    @JvmName("kotlinCompat\$setProperty")
    override fun setProperty(view: T, propName: String, value: Any?) {
        if (propName == ViewProps.POINTER_EVENTS && view is ReactViewGroup) {
            view.pointerEvents = PointerEvents.parsePointerEvents(value as String?)
        } else {
            codegen.setProperty(view, propName, value)
        }
    }

    @Suppress("INAPPLICABLE_JVM_NAME")
    @JvmName("kotlinCompat\$receiveCommand")
    override fun receiveCommand(view: T, commandName: String, args: ReadableArray) =
        codegen.receiveCommand(view, commandName, args)
}
