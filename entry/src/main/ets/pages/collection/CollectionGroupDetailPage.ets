import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { DataManagerFacade } from '../../datamanager/DataManagerFacade';
import {
  CollectionEventViewModel,
  CollectionGalleryDetailViewModel,
  CollectionGroupViewModel,
  CollectionImageViewModel,
  JsonMap
} from '../../datamanager/DataManagerTypes';
import { MarkdownView } from '../../components/MarkdownView';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { markdownTitleText } from '../../utils/markdown/MarkdownParser';

@Entry
@Component
struct CollectionGroupDetailPage {
  @State title: string = '采集详情';
  @State events: CollectionEventViewModel[] = [];
  @State selectedEventId: string = '';
  private detailTabIndex: number = 1;
  private groupId: string = '';

  aboutToAppear(): void {
    this.readParams();
    this.loadGroup();
  }

  private readParams(): void {
    let params = router.getParams() as JsonMap;
    if (!params) {
      return;
    }
    let rawTabIndex = Number(params['tabIndex']);
    if (!isNaN(rawTabIndex)) {
      this.detailTabIndex = rawTabIndex;
    }
    let rawGroupId = params['groupId'];
    this.groupId = rawGroupId === null || rawGroupId === undefined ? '' : String(rawGroupId);
  }

  private loadGroup(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    let facade = new DataManagerFacade(ctx.filesDir);
    facade.ensureReady();
    let group = facade.loadCollectionGroupViewModel(this.detailTabIndex, this.groupId);
    if (group !== null) {
      this.applyGroup(group);
      return;
    }
    this.title = '采集详情';
    this.events = [];
  }

  private applyGroup(group: CollectionGroupViewModel): void {
    this.title = this.readableTitle(group.title, '采集详情');
    this.events = group.events;
  }

  private readableTitle(text: string, fallback: string): string {
    let title = markdownTitleText(text);
    if (title.length > 0) {
      return title;
    }
    return text.length > 0 ? text : fallback;
  }

  private showEventDetail(event: CollectionEventViewModel): void {
    this.selectedEventId = event.id;
  }

  private closeEventDetail(): void {
    this.selectedEventId = '';
  }

  private selectedEvents(): CollectionEventViewModel[] {
    if (this.selectedEventId.length === 0) {
      return [];
    }
    for (let event of this.events) {
      if (event.id === this.selectedEventId) {
        return [event];
      }
    }
    return [];
  }

  private detailText(event: CollectionEventViewModel): string {
    if (event.normalizedFact.length > 0) {
      return event.normalizedFact;
    }
    if (event.fullText.length > 0) {
      return event.fullText;
    }
    return event.summary;
  }

  private imageCountText(event: CollectionEventViewModel): string {
    let count = 0;
    for (let image of event.imageRefs) {
      if (image.available) {
        count++;
      }
    }
    if (count === 0) {
      return '暂无图片';
    }
    return count.toString() + ' 张图片';
  }

  private joinedText(values: string[], separator: string): string {
    let output = '';
    for (let value of values) {
      if (value.length > 0) {
        output = output.length > 0 ? output + separator + value : value;
      }
    }
    return output;
  }

  private galleryCaptureTime(detail: CollectionGalleryDetailViewModel): string {
    if (detail.captureTime.length > 0) {
      return detail.captureTime;
    }
    return detail.date;
  }

  @Builder Thumbnail(event: CollectionEventViewModel) {
    if (event.thumbnailUri.length > 0) {
      Image(event.thumbnailUri)
        .width(76)
        .height(76)
        .objectFit(ImageFit.Cover)
        .backgroundColor('#EEF2F7')
        .borderRadius(10)
    } else {
      Column() {
        Text('暂无图片')
          .fontSize(12)
          .fontColor('#8A92A3')
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
      .width(76)
      .height(76)
      .backgroundColor('#EEF2F7')
      .borderRadius(10)
    }
  }

  @Builder EventRow(event: CollectionEventViewModel) {
    Row() {
      this.Thumbnail(event)
      Column() {
        Text(this.readableTitle(event.summary, '未命名事件'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#151A28')
          .lineHeight(22)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        AiGeneratedBadge({ compact: true })
          .margin({ top: 6 })
        Row() {
          Text(event.time)
            .fontSize(12)
            .fontColor('#7C8494')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.imageCountText(event))
            .fontSize(12)
            .fontColor('#8066FF')
            .maxLines(1)
        }
        .width('100%')
        .margin({ top: 10 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 13 })
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .margin({ bottom: 12 })
    .onClick(() => {
      this.showEventDetail(event);
    })
  }

  @Builder DetailSectionTitle(label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor('#202636')
      .width('100%')
      .margin({ top: 14 })
  }

  @Builder DetailInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#7C8494')
        .width(72)
        .maxLines(1)
      Text(value.length > 0 ? value : '暂无数据')
        .fontSize(12)
        .fontColor('#303746')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder DetailImage(image: CollectionImageViewModel) {
    if (image.available && image.uri.length > 0) {
      Column() {
        Image(image.uri)
          .width(128)
          .height(260)
          .objectFit(ImageFit.Contain)
          .borderRadius(12)
      }
      .width(128)
      .height(260)
      .margin({ right: 10 })
    } else {
      Column() {
        Text('图片暂不可显示')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#596273')
          .maxLines(1)
        Text('图片引用暂不可显示')
          .fontSize(12)
          .fontColor('#8A92A3')
          .margin({ top: 5 })
          .maxLines(1)
        Text(image.ref)
          .fontSize(10)
          .fontColor('#A0A7B5')
          .margin({ top: 6 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .width(220)
      .height(240)
      .padding(12)
      .backgroundColor('#F7F9FC')
      .borderRadius(12)
      .margin({ right: 10 })
    }
  }

  @Builder DetailImages(event: CollectionEventViewModel) {
    if (event.imageRefs.length === 0) {
      Column() {
        Text('暂无图片')
          .fontSize(13)
          .fontColor('#7C8494')
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(86)
      .backgroundColor('#F7F9FC')
      .borderRadius(12)
      .margin({ top: 10 })
    } else {
      Scroll() {
        Row() {
          ForEach(event.imageRefs, (image: CollectionImageViewModel) => {
            this.DetailImage(image)
          }, (image: CollectionImageViewModel, index: number) => event.id + '_image_' + index.toString())
        }
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .height(270)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .margin({ top: 10 })
    }
  }

  @Builder GalleryLongText(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor('#7C8494')
        .maxLines(1)
      Text(value.length > 0 ? value : '暂无数据')
        .fontSize(12)
        .fontColor('#303746')
        .lineHeight(19)
        .width('100%')
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 10 })
  }

  @Builder GalleryDetailCard(detail: CollectionGalleryDetailViewModel) {
    Column() {
      Row() {
        Text(detail.category.length > 0 ? detail.category : '图库')
          .fontSize(11)
          .fontColor('#8066FF')
          .maxLines(1)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#F0ECFF')
          .borderRadius(10)
        Text(this.readableTitle(detail.title, '图库分析详情'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#151A28')
          .layoutWeight(1)
          .margin({ left: 8 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        AiGeneratedBadge({ compact: true })
          .margin({ left: 8 })
      }
      .width('100%')

      this.GalleryLongText('分类', detail.category)
      this.GalleryLongText('标签', this.joinedText(detail.tags, '、'))
      this.GalleryLongText('摘要', detail.summary)
      this.GalleryLongText('分析明细', this.joinedText(detail.details, '\n'))
      this.GalleryLongText('OCR 文本', detail.ocrText)
      this.GalleryLongText('拍摄时间', this.galleryCaptureTime(detail))
      this.GalleryLongText('设备', detail.captureDevice)
      this.GalleryLongText('坐标', detail.captureLocation)
      this.GalleryLongText('地址', detail.address)
      this.GalleryLongText('附近地点', detail.poiName)
      this.GalleryLongText('地图链接', detail.mapUrl)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor('#F7F9FC')
    .borderRadius(12)
    .margin({ top: 10 })
  }

  @Builder GalleryDetails(event: CollectionEventViewModel) {
    if (event.galleryDetails.length > 0) {
      this.DetailSectionTitle('图库分析')
      ForEach(event.galleryDetails, (detail: CollectionGalleryDetailViewModel, index: number) => {
        this.GalleryDetailCard(detail)
      }, (detail: CollectionGalleryDetailViewModel, index: number) =>
        event.id + '_gallery_' + detail.id + '_' + index.toString())
    }
  }

  @Builder EventDetailPanel() {
    if (this.selectedEventId.length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeEventDetail();
          })

        ForEach(this.selectedEvents(), (event: CollectionEventViewModel) => {
          Column() {
            Row() {
              Column() {
                Text(this.readableTitle(event.summary, '事件详情'))
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#11182F')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(event.source)
                  .fontSize(12)
                  .fontColor('#8066FF')
                  .margin({ top: 5 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ right: 12 })
              AiGeneratedBadge({ compact: true })
                .margin({ right: 12 })
              Text('关闭')
                .fontSize(13)
                .fontColor('#5B68FF')
                .onClick(() => {
                  this.closeEventDetail();
                })
            }
            .width('100%')

            Scroll() {
              Column() {
                this.DetailSectionTitle(event.galleryDetails.length > 0 ? '图库图片' : '来源图片')
                this.DetailImages(event)
                this.GalleryDetails(event)

                this.DetailSectionTitle('详情')
                Column() {
                  MarkdownView({ text: this.detailText(event), variant: 'collection_detail' })
                }
                  .width('100%')
                  .padding(10)
                  .backgroundColor('#F7F9FC')
                  .borderRadius(10)
                  .margin({ top: 8 })

                this.DetailSectionTitle('基础信息')
                this.DetailInfoRow('首次出现', event.firstSeenTime)
                this.DetailInfoRow('最近更新', event.lastSeenTime)
                this.DetailInfoRow('来源', event.source)
                this.DetailInfoRow('图片', this.imageCountText(event))

                Blank().height(8)
              }
              .width('100%')
              .constraintSize({ minHeight: '100%' })
              .justifyContent(FlexAlign.Start)
            }
            .width('100%')
            .layoutWeight(1)
            .margin({ top: 8 })
          }
          .width('88%')
          .height('82%')
          .padding(18)
          .backgroundColor(Color.White)
          .borderRadius(18)
          .shadow({ radius: 24, color: '#24000000', offsetX: 0, offsetY: 10 })
        }, (event: CollectionEventViewModel) => event.id)
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('返回')
            .fontSize(14)
            .fontColor('#8066FF')
            .height(36)
            .padding({ left: 12, right: 12 })
            .backgroundColor('#F0ECFF')
            .borderRadius(18)
            .onClick(() => {
              router.back();
            })
          Text(this.title)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#151A28')
            .layoutWeight(1)
            .margin({ left: 12 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          AiGeneratedBadge({ compact: true })
            .margin({ left: 8 })
        }
        .width('86%')
        .margin({ top: 18, bottom: 14 })

        if (this.events.length === 0) {
          Column() {
            Text('暂无已整理记录')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#151A28')
            Text('返回采集页后重新同步')
              .fontSize(12)
              .fontColor('#7C8494')
              .margin({ top: 8 })
          }
          .width('86%')
          .height(140)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)
        } else {
          List({ space: 0 }) {
            ForEach(this.events, (event: CollectionEventViewModel) => {
              ListItem() {
                this.EventRow(event)
              }
              .width('100%')
            }, (event: CollectionEventViewModel) => event.id)
          }
          .width('86%')
          .layoutWeight(1)
          .alignListItem(ListItemAlign.Start)
          .padding({ bottom: 40 })
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Start)
      .backgroundColor('#F4F8FF')

      this.EventDetailPanel()
    }
    .width('100%')
    .height('100%')
  }
}
