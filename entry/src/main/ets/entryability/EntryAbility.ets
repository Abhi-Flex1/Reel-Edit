/*
 * Reel-Edit entry ability.
 *
 * Sets up the native bridge before the page loads, then loads the ArkWeb host
 * which renders the OpenReel editor from the HAP's rawfile bundle.
 */

import { UIAbility, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BridgeHolder } from '../services/BridgeHolder';

const TAG = 'ReelEditEntry';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | undefined = undefined;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, 'onWindowStageCreate');
    this.windowStage = windowStage;
    // The bridge must exist before the page's first bridge call, and the page
    // calls into it as soon as it boots.
    BridgeHolder.create(this.context, windowStage);

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent success');
    });
  }

  /**
   * Applies the system light/dark setting to the hosted page.
   *
   * ArkWeb is configured with WebDarkMode.Auto, so it normally picks the scheme
   * up on its own. Driving it explicitly here also covers a change made while
   * the app is running, and keeps the editor's theme in step with the device
   * even on kernels where the automatic mode does not re-evaluate.
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    const dark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    hilog.info(0x0000, TAG, 'colour mode changed, dark=%{public}s', dark);
    BridgeHolder.setDarkMode(dark);
  }

  onWindowStageDestroy(): void {
    BridgeHolder.release();
    hilog.info(0x0000, TAG, 'onWindowStageDestroy');
  }
}