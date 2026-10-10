import { PrivacyConsent } from '../PrivacyConsent';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { GalleryLocationCacheRecord } from './GalleryTypes';

interface AmapCoordinate {
  latitude: number;
  longitude: number;
}

type AmapJson = Record<string, Object | string | number | boolean | null>;

const AMAP_CONVERT_URL = 'https://restapi.amap.com/v3/assistant/coordinate/convert';
const AMAP_REGEOCODE_URL = 'https://restapi.amap.com/v3/geocode/regeo';

export class GalleryReverseGeocoder {
  // 高德 Web 服务要求 location 使用“经度,纬度”。EXIF GPS 是 WGS84，先转换为高德坐标再逆地理编码。
  async reverse(latitude: number, longitude: number, apiKey: string): Promise<GalleryLocationCacheRecord> {
    let key = apiKey.trim();
    if (key.length === 0) {
      throw new Error('未配置高德 Web 服务 Key');
    }
    let amapCoordinate = await this.convertGpsToAmap(latitude, longitude, key);
    let payload = await this.regeocode(amapCoordinate.latitude, amapCoordinate.longitude, key);
    return this.buildRecord(latitude, longitude, amapCoordinate, payload);
  }

  private async convertGpsToAmap(latitude: number, longitude: number, apiKey: string): Promise<AmapCoordinate> {
    let url = AMAP_CONVERT_URL +
      '?locations=' + encodeURIComponent(longitude.toFixed(6) + ',' + latitude.toFixed(6)) +
      '&coordsys=gps' +
      '&output=json' +
      '&key=' + encodeURIComponent(apiKey);
    let payload = await this.requestJson(url);
    this.ensureAmapOk(payload, '高德坐标转换失败');
    let locations = this.getString(payload, 'locations');
    let parts = locations.split(',');
    if (parts.length < 2) {
      throw new Error('高德坐标转换结果无效');
    }
    let amapLongitude = Number(parts[0]);
    let amapLatitude = Number(parts[1]);
    if (isNaN(amapLatitude) || isNaN(amapLongitude)) {
      throw new Error('高德坐标转换结果不是有效数字');
    }
    return {
      latitude: amapLatitude,
      longitude: amapLongitude
    };
  }

  private async regeocode(latitude: number, longitude: number, apiKey: string): Promise<AmapJson> {
    let url = AMAP_REGEOCODE_URL +
      '?location=' + encodeURIComponent(longitude.toFixed(6) + ',' + latitude.toFixed(6)) +
      '&radius=1000' +
      '&extensions=all' +
      '&output=json' +
      '&key=' + encodeURIComponent(apiKey);
    let payload = await this.requestJson(url);
    this.ensureAmapOk(payload, '高德逆地理编码失败');
    return payload;
  }

  private async requestJson(url: string): Promise<AmapJson> {
    let httpReq = PrivacyConsent.createHttp();
    try {
      let response = await httpReq.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('HTTP ' + response.responseCode.toString() + ': ' + String(response.result));
      }
      return ArkJSON.parse(String(response.result)) as AmapJson;
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      PrivacyConsent.destroyHttp(httpReq);
    }
  }

  private ensureAmapOk(payload: AmapJson, prefix: string): void {
    if (this.getString(payload, 'status') === '1') {
      return;
    }
    let info = this.getString(payload, 'info');
    let infocode = this.getString(payload, 'infocode');
    throw new Error(prefix + (info.length > 0 ? '：' + info : '') +
      (infocode.length > 0 ? ' (' + infocode + ')' : ''));
  }

  private buildRecord(rawLatitude: number, rawLongitude: number, amapCoordinate: AmapCoordinate,
    payload: AmapJson): GalleryLocationCacheRecord {
    let regeocode = this.getMap(payload, 'regeocode');
    let addressComponent = this.getMap(regeocode, 'addressComponent');
    let streetNumber = this.getMap(addressComponent, 'streetNumber');
    let poiName = this.firstPoiName(regeocode);
    let formattedAddress = this.getString(regeocode, 'formatted_address');
    if (formattedAddress.length === 0 && poiName.length > 0) {
      formattedAddress = poiName + '附近';
    }
    return {
      key: rawLatitude.toFixed(6) + ',' + rawLongitude.toFixed(6),
      provider: 'amap',
      rawLatitude: rawLatitude,
      rawLongitude: rawLongitude,
      amapLatitude: amapCoordinate.latitude,
      amapLongitude: amapCoordinate.longitude,
      formattedAddress: formattedAddress,
      province: this.getString(addressComponent, 'province'),
      city: this.getString(addressComponent, 'city'),
      district: this.getString(addressComponent, 'district'),
      township: this.getString(addressComponent, 'township'),
      street: this.streetText(streetNumber),
      poiName: poiName,
      updatedAt: new Date().getTime()
    };
  }

  private streetText(streetNumber: AmapJson): string {
    let street = this.getString(streetNumber, 'street');
    let number = this.getString(streetNumber, 'number');
    if (street.length > 0 && number.length > 0) {
      return street + number;
    }
    return street.length > 0 ? street : number;
  }

  private firstPoiName(regeocode: AmapJson): string {
    let pois = regeocode['pois'];
    if (!Array.isArray(pois) || pois.length === 0) {
      return '';
    }
    let first = pois[0] as AmapJson;
    return this.getString(first, 'name');
  }

  private getMap(map: AmapJson, key: string): AmapJson {
    let value = map[key];
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return {};
    }
    return value as AmapJson;
  }

  private getString(map: AmapJson, key: string): string {
    let value = map[key];
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return '';
  }
}
