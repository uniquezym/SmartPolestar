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
  /**
   * 地图参数。
   *
   * 必须是**稳定引用** —— MapComponent 收到新的 mapOptions 对象会重建底层
   * 地图实例，标记会被一起清掉。页面上任何 @State 变化都会触发 build，
   * 所以这里在 aboutToAppear 里一次性构造好，之后不再换对象。
   */
  private mapOptions: mapCommon.MapOptions = {
    position: { target: { latitude: 0, longitude: 0 }, zoom: 17 },
    myLocationControlsEnabled: false,
    zoomControlsEnabled: false,
    scaleControlsEnabled: false,
    compassControlsEnabled: false
  };
  /** 当前位置是否已经打过标记，避免重复打。 */
  private currentMarked: boolean = false;
  /** 停车位标记是否已经打过。 */
  private parkedMarked: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as ParkedPlaceParams;
    if (params !== undefined && params !== null) {
      this.latitude = params.latitude;
      this.longitude = params.longitude;
      this.parkedTimestamp = params.timestamp;
      // 地点名由概览页直接带过来 —— 本页不再反查，
      // 否则会先闪一下经纬度再跳成地址。
      this.placeName = params.name ?? '';
    }
    this.mapOptions = {
      position: { target: this.parkingLatLng(), zoom: 17 },
      myLocationControlsEnabled: false,
      zoomControlsEnabled: false,
      scaleControlsEnabled: false,
      compassControlsEnabled: false
    };
    this.requestLocationPermission();
    this.loadCurrentLocation();
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
      // 定位拿到时地图可能已经初始化好了，直接补打当前位置标记。
      if (this.mapController !== undefined) {
        this.setupMarkers(this.mapController);
      } else {
        this.frameBothPoints();
      }
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
   * 地图初始化完成：打两个标记、框住两点。
   *
   * 【坑】ArkUI 的 AsyncCallback 在成功时传的 err 是 **null**
   * （有时是 undefined），不是 `{code: 0}`。直接读 err.code 会抛
   * TypeError，而回调里的异常会被静默吞掉 —— 表现就是「地图出来了
   * 但标记一个都没有，也没有应用自己的日志」。所以这里必须先判空。
   */
  private onMapReady(err: BusinessError | null | undefined,
    controller: map.MapComponentController | null | undefined): void {
    try {
      if (err !== undefined && err !== null && err.code !== 0) {
        Log.warn(`地图初始化失败: code=${err.code} ${err.message}`);
        return;
      }
      if (controller === undefined || controller === null) {
        Log.warn('地图初始化回调没有拿到控制器');
        return;
      }
      this.mapController = controller;
      // 地图底图还没加载完时打的标记可能不渲染 —— 底图就绪后再补一次。
      controller.on('mapLoad', () => {
        Log.info('地图底图加载完成');
        this.setupMarkers(controller);
      });
      this.setupMarkers(controller);
    } catch (e) {
      Log.error(`地图初始化回调异常: ${(e as Error).message}`);
    }
  }

  /**
   * 打标记并调整镜头。
   *
   * 两个标记都用自己的图标，不用地图的默认标记 —— 默认标记样式不可控，
   * 而「当前位置」与「停车位置」必须一眼能分清。
   *
   * 「当前位置」用自绘蓝点而不是地图的内置定位图层：内置图层依赖系统定位源，
   * 在应用里表现不稳定（权限刚授予、定位源未就绪时都不显示）。
   */
  private async setupMarkers(controller: map.MapComponentController): Promise<void> {
    if (!this.parkedMarked) {
      try {
        await controller.addMarker({
          position: this.parkingLatLng(),
          icon: $r('app.media.ic_map_car'),
          title: '车辆停放位置',
          snippet: this.displayName(),
          // 图标锚点在底部尖角上 —— 车标的尖角指向停车点。
          anchorU: 0.5,
          anchorV: 1.0
        });
        this.parkedMarked = true;
        Log.info(`停车位标记已添加: ${this.latitude}, ${this.longitude}`);
      } catch (err) {
        const e = err as BusinessError;
        Log.warn(`添加停车位标记失败: code=${e.code} ${e.message}`);
      }
    }

    if (this.currentLatitude >= 0 && !this.currentMarked) {
      try {
        await controller.addMarker({
          position: { latitude: this.currentLatitude, longitude: this.currentLongitude },
          icon: $r('app.media.ic_map_current'),
          title: '当前位置'
        });
        this.currentMarked = true;
        Log.info(`当前位置标记已添加: ${this.currentLatitude}, ${this.currentLongitude}`);
      } catch (err) {
        const e = err as BusinessError;
        Log.warn(`添加当前位置标记失败: code=${e.code} ${e.message}`);
      }
    }

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
          .fontSize(21)
          .fontWeight(FontWeight.Normal)
          .fontColor($r('app.color.app_primary_text'))
      }
      .width('100%')
      .padding({ left: 14, right: 18, top: 16, bottom: 14 })
      .backgroundColor($r('app.color.app_background'))

      // ---------- 地图 ----------
      MapComponent({
        mapOptions: this.mapOptions,
        // Map Kit 成功时传的 err 是 null，签名要允许 null 才能往下传。
        mapCallback: (err: BusinessError | null, controller: map.MapComponentController | null) => {
          this.onMapReady(err, controller);
        }
      })
        .width('100%')
        .layoutWeight(1)

      // ---------- 底部信息卡 ----------
      Column({ space: 10 }) {
        Text(this.displayName())
          .fontSize(16)
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
  /** 概览页已解析好的地点名（省市区镇 + AOI）。 */
  name: string = '';
}
