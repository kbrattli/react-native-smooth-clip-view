package com.smoothclipview

import android.view.View
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewGroupManager
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.SmoothClipBackdropViewManagerDelegate
import com.facebook.react.viewmanagers.SmoothClipBackdropViewManagerInterface

@ReactModule(name = SmoothClipBackdropViewManager.NAME)
class SmoothClipBackdropViewManager : ViewGroupManager<SmoothClipBackdropView>(),
    SmoothClipBackdropViewManagerInterface<SmoothClipBackdropView> {
    private val delegate =
        SmoothClipBackdropViewManagerDelegate<SmoothClipBackdropView, SmoothClipBackdropViewManager>(this)

    // Fabric delivers the prop before the transaction ends; bind once per
    // transaction, after every prop of it has landed.
    private val pendingDriverIds = java.util.WeakHashMap<SmoothClipBackdropView, Double>()

    override fun getName(): String = NAME

    override fun getDelegate(): ViewManagerDelegate<SmoothClipBackdropView> = delegate

    override fun createViewInstance(context: ThemedReactContext): SmoothClipBackdropView =
        SmoothClipBackdropView(context)

    @ReactProp(name = "driverId")
    override fun setDriverId(view: SmoothClipBackdropView, value: Double) {
        pendingDriverIds[view] = value
    }

    override fun addView(parent: SmoothClipBackdropView, child: View, index: Int) {
        parent.contentContainer.addView(child, index)
    }

    override fun getChildCount(parent: SmoothClipBackdropView): Int =
        parent.contentContainer.childCount

    override fun getChildAt(parent: SmoothClipBackdropView, index: Int): View =
        parent.contentContainer.getChildAt(index)

    override fun removeViewAt(parent: SmoothClipBackdropView, index: Int) {
        parent.contentContainer.removeViewAt(index)
    }

    override fun onAfterUpdateTransaction(view: SmoothClipBackdropView) {
        super.onAfterUpdateTransaction(view)
        val driverId = pendingDriverIds.remove(view) ?: return
        view.bindDriver(driverId)
    }

    override fun onDropViewInstance(view: SmoothClipBackdropView) {
        pendingDriverIds.remove(view)
        view.bindDriver(0.0)
        super.onDropViewInstance(view)
    }

    companion object {
        const val NAME = "SmoothClipBackdropView"
    }
}
