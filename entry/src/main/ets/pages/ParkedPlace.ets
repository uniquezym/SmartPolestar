import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { MapComponent, map, mapCommon } from '@kit.MapKit';
import { AppIcon, AppIconName } from '../components/Icons';
import { Log } from '../common/Log';
import { CoordinateTransform } from '../core/vehicle/CoordinateTransform';
import { MapLauncher } from '../core/vehicle/MapLauncher';
import { ParkedPlaceInfo } from '../core/vehicle/ParkedPlaceInfo';
import { PetalMapLauncher } from '../core/vehicle/PetalMapLauncher';
import { PlaceResolver } from '../core/vehicle/PlaceResolver';

/**
 * 停车位置地点预览页。
 *
 * 页面结构（自上而下）：
 *   地图 —— 当前位置用系统蓝点，停车位置打车辆标记，镜头框住两点
 *   返回按钮（浮在地图左上角）
 *   底部信息卡 —— 完整地址（省 / 市 / 区 / 镇 + AOI）、已停放时长、与当前的距离
 *   「找车」按钮 —— 跳花瓣地图路线规划（终点停车位，步行）
 *
 * 按需求去掉了右上角图标、「拍照记录」卡片与「缴费」按钮。
 *
 * 【坐标系】车辆坐标是 GCJ02，Map Kit 大陆区底图也是 GCJ02，直接用；
 * 系统定位给的是 WGS84，参与测距与镜头计算前先转 GCJ02。
 */
@Entry
@Component
struct ParkedPlace {
  /** 停车位纬度（GCJ02）。 */
  private latitude: number = 0;
  /** 停车位经度（GCJ02）。 */
  private longitude: number = 0;
  /** 停车时刻（毫秒时间戳），0 表示未知。 */
  private parkedTimestamp: number = 0;

  /** 完整地点名（省市区镇 + AOI）。 */
  @State placeName: string = '';
  /** 当前定位纬度（GCJ02），-1 表示还没拿到。 */
  @State currentLatitude: number = -1;
  /** 当前定位经度（GCJ02），-1 表示还没拿到。 */
  @State currentLongitude: number = -1;

  /** 地图控制器。 */
  private mapController: map.MapComponentController | undefined = undefined;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as ParkedPlaceParams;
    if (params !== undefined && params !== null) {
      this.latitude = params.latitude;
      this.longitude = params.longitude;
      this.parkedTimestamp = params.timestamp;
    }
    this.resolvePlaceName();
    this.requestLocationPermission();
    this.loadCurrentLocation();
  }

  /**
   * 反查停车点地址。
   *
   * 概览页已经解析过一次，这里再调一次是为了在概览页还没解析完
   * 就被点进来的情况下也能拿到完整地址 —— PlaceResolver 内部有缓存，
   * 重复调用不会产生额外请求。
   */
  private async resolvePlaceName(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const info = await PlaceResolver.resolve(context, this.latitude, this.longitude);
    if (info !== undefined) {
      this.placeName = info.fullName();
    }
  }

  /**
   * 申请定位权限。
   *
   * 概览页进入时已经申请过一次，这里再申请一次是为了直接从别处进本页的情况。
   * 已授权时系统直接返回，不会再弹窗。
   */
  private async requestLocationPermission(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(context, [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ]);
    } catch (err) {
      Log.warn(`申请位置权限失败: ${(err as Error).message}`);
    }
  }

  /**
   * 取当前定位（系统定位是 WGS84，转成 GCJ02 才能与车辆坐标放一起算）。
   */
  private async loadCurrentLocation(): Promise<void> {
    try {
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.ACCURACY,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        timeoutMs: 10000,
        maxAccuracy: 0
      };
      const location = await geoLocationManager.getCurrentLocation(request);
      const gcj = CoordinateTransform.wgs2Gcj(location.latitude, location.longitude);
      this.currentLatitude = gcj[0];
      this.currentLongitude = gcj[1];
      this.frameBothPoints();
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`获取当前位置失败: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 镜头框住「当前位置」与「停车位置」两点。
   *
   * 两点几乎重合时 bounds 会退化成一条线，这时直接居中到停车位。
   */
  private frameBothPoints(): void {
    const controller = this.mapController;
    if (controller === undefined) {
      return;
    }
    if (this.currentLatitude < 0) {
      controller.animateCamera(map.newLatLng(this.parkingLatLng(), 17));
      return;
    }
    const latSpan = Math.abs(this.currentLatitude - this.latitude);
    const lonSpan = Math.abs(this.currentLongitude - this.longitude);
    if (latSpan < 0.002 && lonSpan < 0.002) {
      controller.animateCamera(map.newLatLng(this.parkingLatLng(), 17));
      return;
    }
    // 留一点余量，标记不至于贴在边缘。
    const padLat = Math.max(latSpan * 0.35, 0.001);
    const padLon = Math.max(lonSpan * 0.35, 0.001);
    const northeast: mapCommon.LatLng = {
      latitude: Math.max(this.currentLatitude, this.latitude) + padLat,
      longitude: Math.max(this.currentLongitude, this.longitude) + padLon
    };
    const southwest: mapCommon.LatLng = {
      latitude: Math.min(this.currentLatitude, this.latitude) - padLat,
      longitude: Math.min(this.currentLongitude, this.longitude) - padLon
    };
    const bounds: mapCommon.LatLngBounds = { northeast: northeast, southwest: southwest };
    controller.animateCamera(map.newLatLngBounds(bounds, 80));
  }

  /**
   * 地图初始化完成：打停车位标记、开我的位置图层。
   */
  private onMapReady(err: BusinessError, controller: map.MapComponentController): void {
    if (err.code !== 0) {
      Log.warn(`地图初始化失败: code=${err.code} ${err.message}`);
      return;
    }
    this.mapController = controller;
    controller.setMyLocationEnabled(true);
    // 打标记是异步的，失败只影响标记显示，不该变成未捕获异常。
    controller.addMarker({
      position: this.parkingLatLng(),
      title: '车辆停放位置',
      snippet: this.displayName()
    }).catch((err: BusinessError) => {
      Log.warn(`添加停车位标记失败: code=${err.code} ${err.message}`);
    });
    this.frameBothPoints();
  }

  /**
   * 停车位坐标。
   */
  private parkingLatLng(): mapCommon.LatLng {
    return { latitude: this.latitude, longitude: this.longitude };
  }

  /**
   * 完整地点名，缺失时退回坐标。
   */
  private displayName(): string {
    if (this.placeName.length > 0) {
      return this.placeName;
    }
    return `${this.latitude.toFixed(4)}, ${this.longitude.toFixed(4)}`;
  }

  /**
   * 已停放时长文案。
   */
  private parkedText(): string {
    if (this.parkedTimestamp <= 0) {
      return '停放时间未知';
    }
    let ts = this.parkedTimestamp;
    if (ts < 100000000000) {
      ts *= 1000;
    }
    const delta = Date.now() - ts;
    if (delta < 0) {
      return '已停放 —';
    }
    const minutes = Math.floor(delta / 60000);
    if (minutes < 1) {
      return '已停放 不到 1 分钟';
    }
    if (minutes < 60) {
      return `已停放 ${minutes} 分钟`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
      return `已停放 ${hours} 时 ${minutes % 60} 分`;
    }
    return `已停放 ${Math.floor(hours / 24)} 天 ${hours % 24} 时`;
  }

  /**
   * 与当前位置的直线距离。
   */
  private distanceText(): string {
    if (this.currentLatitude < 0) {
      return '';
    }
    const meters = ParkedPlaceInfo.distanceMeters(
      this.currentLatitude, this.currentLongitude, this.latitude, this.longitude);
    if (meters < 1000) {
      return `距你 ${Math.round(meters)} 米`;
    }
    return `距你 ${(meters / 1000).toFixed(1)} 公里`;
  }

  /**
   * 「找车」—— 跳花瓣地图规划到停车位的路线。
   *
   * 回退链：花瓣地图路线规划 → 花瓣地图地点详情 → 系统地图 → 内置在线地图。
   */
  private async findCar(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const opened = await PetalMapLauncher.openRoutePlan(
      context, this.latitude, this.longitude, this.displayName());
    if (opened) {
      return;
    }
    const detail = await PetalMapLauncher.openPoiDetail(
      context, this.latitude, this.longitude, this.displayName());
    if (detail) {
      return;
    }
    const geo = await MapLauncher.open(context, this.latitude, this.longitude, this.displayName());
    if (!geo) {
      // 系统没有可响应 geo: 的地图应用，退到内置在线地图
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Map',
        params: {
          latitude: this.latitude,
          longitude: this.longitude,
          name: this.displayName()
        }
      });
    }
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

        Text('车辆停放位置')
          .fontSize(17)
          .fontWeight(FontWeight.Normal)
          .fontColor($r('app.color.app_primary_text'))
      }
      .width('100%')
      .padding({ left: 14, right: 18, top: 16, bottom: 14 })
      .backgroundColor($r('app.color.app_background'))

      // ---------- 地图 ----------
      MapComponent({
        mapOptions: {
          position: {
            target: this.parkingLatLng(),
            zoom: 17
          },
          myLocationControlsEnabled: true,
          zoomControlsEnabled: false,
          scaleControlsEnabled: false,
          compassControlsEnabled: false
        },
        mapCallback: (err: BusinessError, controller: map.MapComponentController) => {
          this.onMapReady(err, controller);
        }
      })
        .width('100%')
        .layoutWeight(1)

      // ---------- 底部信息卡 ----------
      Column({ space: 10 }) {
        Text(this.displayName())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: 10 }) {
          Text(this.parkedText())
            .fontSize(12)
            .fontColor($r('app.color.app_tertiary_text'))
          if (this.distanceText().length > 0) {
            Text(this.distanceText())
              .fontSize(12)
              .fontColor($r('app.color.app_tertiary_text'))
          }
        }
        .width('100%')

        Button('找车')
          .width('100%')
          .height(48)
          .borderRadius(8)
          .backgroundColor($r('app.color.app_accent'))
          .fontColor($r('app.color.app_on_accent'))
          .fontSize(15)
          .onClick(() => {
            this.findCar();
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 18 })
      .backgroundColor($r('app.color.app_card_background'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}

/**
 * 路由参数。
 */
class ParkedPlaceParams {
  latitude: number = 0;
  longitude: number = 0;
  timestamp: number = 0;
}
