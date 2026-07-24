package com.smoothclipview

import android.graphics.Color
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.SmoothClipViewViewManagerInterface
import com.facebook.react.viewmanagers.SmoothClipViewViewManagerDelegate

@ReactModule(name = SmoothClipViewViewManager.NAME)
class SmoothClipViewViewManager : SimpleViewManager<SmoothClipViewView>(),
  SmoothClipViewViewManagerInterface<SmoothClipViewView> {
  private val mDelegate: ViewManagerDelegate<SmoothClipViewView>

  init {
    mDelegate = SmoothClipViewViewManagerDelegate(this)
  }

  override fun getDelegate(): ViewManagerDelegate<SmoothClipViewView>? {
    return mDelegate
  }

  override fun getName(): String {
    return NAME
  }

  public override fun createViewInstance(context: ThemedReactContext): SmoothClipViewView {
    return SmoothClipViewView(context)
  }

  @ReactProp(name = "color")
  override fun setColor(view: SmoothClipViewView?, color: Int?) {
    view?.setBackgroundColor(color ?: Color.TRANSPARENT)
  }

  companion object {
    const val NAME = "SmoothClipViewView"
  }
}
