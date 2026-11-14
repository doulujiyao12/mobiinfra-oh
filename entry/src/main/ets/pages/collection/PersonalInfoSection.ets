import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { MemoryPerson, PERSON_SLOTS, PERSON_FIELDS, PersonField, PersonSlot, PERSON_MEMORY_REVISION_KEY } from '../../datamanager/PersonMemory';
import { PersonMemoryStore } from '../../datamanager/PersonMemoryStore';

interface PersonPageParams { personId: string; }
@Component
export struct PersonalInfoSection {
  @Prop compact: boolean = true;
  @StorageProp(PERSON_MEMORY_REVISION_KEY) @Watch('reload') revision: number = 0;
  @State private people: MemoryPerson[] = [];
  @State private error: string = '';
  aboutToAppear(): void { this.reload(); }
  private reload(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.people = new PersonMemoryStore(context.filesDir).people(); this.error = '';
    } catch (e) { this.error = '人物资料暂时无法读取'; }
  }
  private detail(slot: PersonSlot): string {
    const person = this.people.find((item: MemoryPerson): boolean => item.id === slot.id);
    if (!person) { return '点击填写'; }
    const count = PERSON_FIELDS.filter((field: PersonField): boolean => !!person.values[field.key]).length;
    if (!count) { return '点击填写'; }
    return (person.values['name'] || person.values['wechat_name'] || '已填写') + ' · ' + count + ' 项信息';
  }
  private open(slot: PersonSlot): void {
    const params: PersonPageParams = { personId: slot.id };
    router.pushUrl({ url: 'pages/collection/PersonInfoPage', params: params });
  }
  private overview(): string {
    if (this.error) { return '暂时无法读取，点击重试'; }
    const count = this.people.filter((person: MemoryPerson): boolean =>
      PERSON_FIELDS.some((field: PersonField): boolean => !!person.values[field.key])).length;
    return count > 0 ? '已填写 ' + count + ' 位资料' : '管理我与家人的资料';
  }
  @Builder private Entry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        Image($r('app.media.settings_people')).width(25).height(25).objectFit(ImageFit.Contain).flexShrink(0)
        Column({ space: 5 }) {
          Text('人物资料').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
            .width('100%')
          Text(this.overview()).fontSize(13).fontColor($r('app.color.ui_text_secondary'))
            .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('›').fontSize(25).fontColor($r('app.color.ui_text_muted')).width(14)
      }.width('100%')
    }.width('100%').padding(18).borderRadius(20).backgroundColor($r('app.color.ui_surface'))
      .accessibilityText('人物资料，' + this.overview())
      .onClick((): void => {
        if (this.error) { this.reload(); return; }
        router.pushUrl({ url: 'pages/collection/PeopleInfoPage' });
      })
  }
  @Builder private PeopleList() {
    ForEach(PERSON_SLOTS, (slot: PersonSlot, index: number) => {
      if (index > 0) {
        Row() {
          Divider().strokeWidth(0.5).color(AppTheme.border('#E0E5EF'))
        }.width('100%').padding({ left: 72, right: 18 })
      }
      Row({ space: 14 }) {
        Text(slot.monogram).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text(slot.color))
          .textAlign(TextAlign.Center).width(38).height(38).borderRadius(19).backgroundColor(AppTheme.background('#ECF1F9'))
        Column({ space: 5 }) {
          Text(slot.label).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#161C2D'))
          Text(this.detail(slot)).fontSize(12).fontColor(AppTheme.text('#7A8292')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('›').fontSize(25).fontColor(AppTheme.text('#A2A8B5')).width(20).textAlign(TextAlign.Center)
      }.width('100%').constraintSize({ minHeight: 76 }).padding({ left: 18, right: 18, top: 14, bottom: 14 })
        .onClick((): void => { this.open(slot); })
        .accessibilityGroup(true).accessibilityText('编辑' + slot.label + '的信息')
    }, (slot: PersonSlot): string => slot.id)
    if (this.error) {
      Text(this.error + '，点击重试').fontSize(13).fontColor(AppTheme.text('#BC5363')).padding(18)
        .onClick((): void => { this.reload(); })
    }
  }
  build() {
    Column() {
      if (this.compact) { this.Entry() } else { this.PeopleList() }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
