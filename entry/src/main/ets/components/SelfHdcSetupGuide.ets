@Component
export struct SelfHdcSetupGuide {
  build() {
    Column({ space: 12 }) {
      Text('按图完成设置').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')
      Text() {
        Span('① 打开“设置 > 关于手机”，找到 ')
        Span('软件版本').fontWeight(FontWeight.Bold).fontColor('#4F5FEA')
        Span('，')
        Span('连续快速点击 7 次').fontWeight(FontWeight.Bold).fontColor('#4F5FEA')
        Span('，开启开发者模式。')
      }.fontSize(14).lineHeight(22).fontColor('#344054').width('100%')
      Image($r('app.media.phone_hdc_developer_guide')).width('100%').aspectRatio(1053 / 915)
        .objectFit(ImageFit.Contain).borderRadius(12).accessibilityText('关于手机示意图：红框标出软件版本，连续点击七次')
      Text() {
        Span('② 先连接 ')
        Span('Wi-Fi').fontWeight(FontWeight.Bold).fontColor('#4F5FEA')
        Span('，再在设置中搜索 ')
        Span('无线调试').fontWeight(FontWeight.Bold).fontColor('#4F5FEA')
        Span(' 并开启，查看 ')
        Span('IP 地址和端口').fontWeight(FontWeight.Bold).fontColor('#4F5FEA')
        Span('。')
      }.fontSize(14).lineHeight(22).fontColor('#344054').width('100%')
      Image($r('app.media.phone_hdc_wireless_guide')).width('100%').aspectRatio(1080 / 781)
        .objectFit(ImageFit.Contain).borderRadius(12).accessibilityText('无线调试示意图：开启开关，红框标出IP地址和连接端口')
      Text('图片仅为示例，请使用您自己手机上显示的地址。').fontSize(12).lineHeight(18).fontColor('#B56812').width('100%')
      Text() {
        Span('③ 在“我的 > 手机 HDC”中，按无线调试页面填写 ')
        Span('IP 地址和连接端口').fontWeight(FontWeight.Bold).fontColor('#4F5FEA')
        Span('。IP 自动更新不可用时，关闭“自动更新手机 Wi-Fi IP”后手动填写。')
      }.fontSize(14).lineHeight(22).fontColor('#344054').width('100%')
      Text('填写的是 HDC 连接端口，不是配对码端口或桌面服务端口。重新开启无线调试后，端口可能变化。首次连接时，请手动允许系统调试授权弹窗。')
        .fontSize(12).lineHeight(19).fontColor('#667085').width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
  }
}
