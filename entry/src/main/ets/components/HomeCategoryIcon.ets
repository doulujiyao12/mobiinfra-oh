// The 2172 x 724 atlas contains 6 x 2 cells of 362 px. These are the
// visible artwork centers inside each cell, excluding the white margins.
const CATEGORY_ICON_CELL_PX: number = 362;
const CATEGORY_ICON_CENTER_X: number[] = [
  223, 210, 191.5, 178.5, 180.5, 150.5,
  210, 196.5, 182, 158.5, 166.5, 140.5
];
const CATEGORY_ICON_CENTER_Y: number[] = [
  202.5, 216.5, 221.5, 210, 214.5, 222,
  153, 148.5, 150, 149, 156, 163
];

@Component
export struct HomeCategoryIcon {
  @Prop iconIndex: number = 0;
  @Prop iconSize: number = 48;

  private cellIndex(): number {
    return Math.max(0, Math.min(11, Math.floor(this.iconIndex)));
  }

  private visualOffsetX(): number {
    return (0.5 - CATEGORY_ICON_CENTER_X[this.cellIndex()] / CATEGORY_ICON_CELL_PX) * this.iconSize;
  }

  private visualOffsetY(): number {
    return (0.5 - CATEGORY_ICON_CENTER_Y[this.cellIndex()] / CATEGORY_ICON_CELL_PX) * this.iconSize;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Crop this cell first so centering cannot reveal a neighboring icon.
      Stack({ alignContent: Alignment.TopStart }) {
        Image($r('app.media.home_category_icons'))
          .width(this.iconSize * 6)
          .height(this.iconSize * 2)
          .objectFit(ImageFit.Fill)
          .translate({
            x: -(this.cellIndex() % 6) * this.iconSize,
            y: -Math.floor(this.cellIndex() / 6) * this.iconSize
          })
      }
      .width(this.iconSize)
      .height(this.iconSize)
      .clip(true)
      .translate({ x: this.visualOffsetX(), y: this.visualOffsetY() })
    }
    .width(this.iconSize)
    .height(this.iconSize)
    // Match the atlas's white illustration plate when the cropped cell moves.
    .backgroundColor(Color.White)
    .borderRadius(this.iconSize / 2)
    .clip(true)
  }
}
