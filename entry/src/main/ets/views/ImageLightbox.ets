// 图片灯箱 (对齐 web 版本 .img-lightbox)
@Component
export struct ImageLightbox {
  @Prop visible: boolean = false;
  @Prop imageUrl: string = '';
  private onClose: () => void = (): void => {};

  build() {
    if (this.visible) {
      Stack() {
        // 背景
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#CC000000')
          .onClick(() => {
            this.onClose();
          })

        // 图片
        Image(this.imageUrl)
          .objectFit(ImageFit.Contain)
          .constraintSize({ maxWidth: '90%', maxHeight: '80%' })
          .borderRadius(24)
          .backgroundColor(Color.Black)
          .shadow({ radius: 24, color: '#4D000000', offsetX: 0, offsetY: 8 })
          .onClick(() => {
            this.onClose();
          })

        // 关闭按钮
        Button() {
          Text('✕')
            .fontSize(20)
            .fontColor($r('app.color.text_primary'))
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor('#FFFFFFD9')
        .position({ x: '100%', y: 56 })
        .translate({ x: -56, y: 0 })
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
    }
  }
}
