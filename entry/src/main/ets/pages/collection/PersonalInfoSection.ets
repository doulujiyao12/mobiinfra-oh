import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { MemoryPerson, PERSON_SLOTS, PERSON_FIELDS, PersonField, PersonSlot, PERSON_MEMORY_REVISION_KEY } from '../../datamanager/PersonMemory';
import { PersonMemoryStore } from '../../datamanager/PersonMemoryStore';

interface PersonPageParams { personId: string; }
@Component
export struct PersonalInfoSection {
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
  build() {
    Column() {
      ForEach(PERSON_SLOTS, (slot: PersonSlot, index: number) => {
        if (index > 0) {
          Row() {
            Divider().strokeWidth(0.5).color(AppTheme.border('#E0E5EF'))
          }.width('100%').padding({ left: 60 })
        }
        Row({ space: 14 }) {
          Text(slot.monogram).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text(slot.color))
            .textAlign(TextAlign.Center).width(44).height(44).borderRadius(14).backgroundColor(AppTheme.background('#ECF1F9'))
          Column({ space: 5 }) {
            Text(slot.label).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#161C2D'))
            Text(this.detail(slot)).fontSize(12).fontColor(AppTheme.text('#7A8292')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('›').fontSize(25).fontColor(AppTheme.text('#A2A8B5')).width(20).textAlign(TextAlign.Center)
        }.width('100%').height(76).onClick((): void => { this.open(slot); })
          .accessibilityGroup(true).accessibilityText('编辑' + slot.label + '的信息')
      }, (slot: PersonSlot): string => slot.id)
      if (this.error) {
        Text(this.error + '，点击重试').fontSize(13).fontColor(AppTheme.text('#BC5363')).onClick((): void => { this.reload(); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
