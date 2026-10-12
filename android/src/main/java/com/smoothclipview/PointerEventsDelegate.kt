package com.smoothclipview

import com.facebook.react.bridge.ReadableArray
import com.facebook.react.uimanager.PointerEvents
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.ViewProps
import com.facebook.react.views.view.ReactViewGroup

/** Codegen delegates drop `pointerEvents` (only `ReactViewManager` applies it). */
internal class PointerEventsDelegate<T : ReactViewGroup>(
    private val codegen: ViewManagerDelegate<T>,
) : ViewManagerDelegate<T> {
    override fun setProperty(view: T, propName: String, value: Any?) {
        if (propName == ViewProps.POINTER_EVENTS) {
            view.pointerEvents = PointerEvents.parsePointerEvents(value as String?)
        } else {
            codegen.setProperty(view, propName, value)
        }
    }

    override fun receiveCommand(view: T, commandName: String, args: ReadableArray) =
        codegen.receiveCommand(view, commandName, args)
}
