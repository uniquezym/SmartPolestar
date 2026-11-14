import { webview } from '@kit.ArkWeb';
import { AppIcon, AppIconName } from '../components/Icons';
import { Log } from '../common/Log';

/**
 * 内置地图页 —— 系统地图拉起失败时的兜底。
 *
 * 用 Web 加载在线地图并居中到停车坐标，保证「点击位置能看到地图」这件事
 * 在任何设备上都能完成。
 */
@Entry
@Component
struct Map {
  /** 停车纬度。 */
  private latitude: number = 0;
  /** 停车经度。 */
  private longitude: number = 0;
  /** 地点名。 */
  private placeName: string = '';
  /** 控制器。 */
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as MapParams;
    if (params !== undefined && params !== null) {
      this.latitude = params.latitude;
      this.longitude = params.longitude;
      this.placeName = params.name;
    }
  }

  /**
   * 在线地图 URL：居中到坐标并打点。
   */
  private mapUrl(): string {
    const zoom = 17;
    const lat = this.latitude.toFixed(6);
    const lon = this.longitude.toFixed(6);
    return `https://uri.amap.com/marker?position=${lon},${lat}&name=${encodeURIComponent(this.placeName.length > 0 ? this.placeName : '车辆停放位置')}&src=SmartPolestar&coordinate=gaode&callnative=0&zoom=${zoom}`;
  }

  build() {
    Column() {
      // ---------- 标题栏 ----------
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          AppIcon({ name: AppIconName.CHEVRON_DOWN, iconSize: 18, color: $r('app.color.app_primary_text') })
            .width(18)
            .height(18)
            .rotate({ angle: 90 })
        }
        .width(32)
        .height(32)
        .borderRadius(4)
        .border({ width: 1, color: $r('app.color.app_rule') })
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })

        Column({ space: 3 }) {
          Text('车辆停放位置')
            .fontSize(17)
            .fontWeight(FontWeight.Normal)
            .fontColor($r('app.color.app_primary_text'))
          Text(this.placeName.length > 0 ? this.placeName : `${this.latitude.toFixed(4)}, ${this.longitude.toFixed(4)}`)
            .fontSize(11)
            .fontColor($r('app.color.app_tertiary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 14, right: 18, top: 16, bottom: 14 })
      .backgroundColor($r('app.color.app_background'))

      // ---------- 地图 ----------
      Web({ src: this.mapUrl(), controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .onErrorReceive((event) => {
          Log.warn('地图页面加载失败');
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}

/**
 * 路由参数。
 */
class MapParams {
  latitude: number = 0;
  longitude: number = 0;
  name: string = '';
}
