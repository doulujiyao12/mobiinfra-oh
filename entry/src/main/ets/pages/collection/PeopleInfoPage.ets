import { router } from '@kit.ArkUI';
import { AppHeader, APP_HEADER_CONTENT_GAP } from '../../components/AppHeader';
import { FrostedPage } from '../../components/FrostedPage';
import { PersonalInfoSection } from './PersonalInfoSection';

@Entry
@Component
struct PeopleInfoPage {
  private scroller: Scroller = new Scroller();
  @Builder private Header() {
    AppHeader({ title: '人物资料', showBackButton: true, onBackClick: (): void => { router.back(); } })
  }
  @Builder private Content() {
    Scroll(this.scroller) {
      Column() {
        Column() { PersonalInfoSection({ compact: false }) }.width('100%')
          .backgroundColor($r('app.color.ui_surface')).borderRadius(22).clip(true)
      }.width('92%').constraintSize({ maxWidth: 720 }).padding({ top: APP_HEADER_CONTENT_GAP, bottom: 32 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
  build() {
    Column() {
      FrostedPage({ pageBackgroundColor: '#F6F7F9', scrollers: [this.scroller],
        headerBuilder: (): void => { this.Header(); }, contentBuilder: (): void => { this.Content(); } })
    }.width('100%').height('100%')
  }
}
