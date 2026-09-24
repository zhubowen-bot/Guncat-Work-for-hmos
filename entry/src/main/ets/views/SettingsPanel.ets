import { ApiConfig } from '../model/ApiConfig';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { SearchEngineSettings, SEARCH_ENGINE_BING, SEARCH_ENGINE_BRAVE, SEARCH_ENGINE_TAVILY,
  SEARCH_ENGINE_EXA, SEARCH_ENGINE_METASO, SEARCH_ENGINE_FIRECRAWL,
  searchEngineNeedsApiKey, searchEngineSupportsBaseUrl, searchEngineLabel } from '../service/LocalWebSearch';

// API 设置弹层 (对齐 web 版本 .modal / .settings)
@Component
export struct SettingsPanel {
  // @Watch: 面板从隐藏变为打开时强制把 @Prop 同步到 @State
  // aboutToAppear 在组件首次创建就跑, 那时 vm.init() 还没结束, 读到的是默认空值
  // 后续 vm.apiConfig 加载完成不会再触发 aboutToAppear, 必须靠 visible 变化时再同步一次
  @Prop @Watch('onVisibleChange') visible: boolean = false;
  @Prop @Watch('onProfileChange') initProfileId: string = '';
  @Prop initProfileName: string = '默认配置';
  @Prop profileNames: string[] = [];
  @Prop selectedProfileIndex: number = 0;
  // 父组件传入的初始值 (只读). 父级用 @State vm 传过来,
  // 每次重新打开 SettingsPanel (条件渲染导致组件重建) 时 aboutToAppear 会重新同步
  @Prop initProvider: string = 'openai-completions';
  @Prop initBaseUrl: string = '';
  @Prop initApiKey: string = '';
  @Prop initModel: string = '';
  @Prop initTemperature: string = '';
  @Prop initTopP: string = '';
  @Prop initMaxTokens: string = '';
  @Prop initExtraBody: string = '';
  @Prop initAutoSuffix: boolean = true;
  // 本地内置联网搜索配置(完整 JSON, 按引擎分字段保存, 面板内切换引擎不丢其他引擎配置)
  @Prop initLocalSearchJson: string = '';
  @Prop initMmBaseUrl: string = '';
  @Prop initMmApiKey: string = '';
  @Prop initMmModel: string = '';
  @Prop initMmPreparseEnabled: boolean = true;
  // 工作副本 (用户可编辑). 改回 @State, 不再被父级覆盖
  @State provider: string = 'openai-completions';
  @State profileName: string = '默认配置';
  @State baseUrl: string = '';
  @State apiKey: string = '';
  @State model: string = '';
  @State temperature: string = '';
  @State topP: string = '';
  @State maxTokens: string = '';
  @State extraBody: string = '';
  @State autoSuffix: boolean = true;
  @State mmBaseUrl: string = '';
  @State mmApiKey: string = '';
  @State mmModel: string = '';
  @State mmPreparseEnabled: boolean = true;
  // 本地联网搜索可见编辑字段(仅当前选中引擎); 完整配置存 searchDraft(普通字段, 保存时整体落盘)
  @State searchOpen: boolean = false;
  @State searchEngine: string = 'bing';
  @State searchApiKey: string = '';
  @State searchBaseUrl: string = '';
  private searchDraft: SearchEngineSettings = new SearchEngineSettings();
  // 引擎固定顺序(与 Select 选项一致); struct 不支持 static, 用实例字段
  private searchEngineIds: string[] = [
    SEARCH_ENGINE_BING, SEARCH_ENGINE_BRAVE, SEARCH_ENGINE_TAVILY,
    SEARCH_ENGINE_EXA, SEARCH_ENGINE_METASO, SEARCH_ENGINE_FIRECRAWL
  ];
  @State advancedOpen: boolean = false;
  @State multimodalOpen: boolean = false;

  private onClose: () => void = (): void => {};
  private onSave: (name: string, api: ApiConfig, mm: MultimodalConfig,
    search: SearchEngineSettings) => void =
    (_name: string, _a: ApiConfig, _m: MultimodalConfig, _s: SearchEngineSettings): void => {};
  private onAddProfile: () => void = (): void => {};
  private onSelectProfile: (index: number) => void = (_index: number): void => {};

  aboutToAppear(): void {
    this.syncFromInit();
  }

  onVisibleChange(): void {
    // 面板打开时 (false → true) 强制同步一次 @Prop → @State,
    // 解决 vm.init() 在组件创建之后才完成导致的初始空值问题
    if (this.visible) {
      this.syncFromInit();
    }
  }

  onProfileChange(): void {
    // @Watch 触发时，同一轮父组件刷新的其他 @Prop 可能尚未全部提交。
    // 延迟到下一帧再读取，避免表单内容总是落后当前配置一次。
    setTimeout(() => {
      this.syncFromInit();
    }, 0);
  }

  private syncFromInit(): void {
    this.profileName = this.initProfileName;
    this.provider = this.initProvider;
    this.baseUrl = this.initBaseUrl;
    this.apiKey = this.initApiKey;
    this.model = this.initModel;
    this.temperature = this.initTemperature;
    this.topP = this.initTopP;
    this.maxTokens = this.initMaxTokens;
    this.extraBody = this.initExtraBody;
    this.autoSuffix = this.initAutoSuffix;
    this.searchDraft = SearchEngineSettings.parse(this.initLocalSearchJson);
    this.searchEngine = this.searchDraft.engine;
    this.searchApiKey = this.searchDraft.apiKeyForEngine(this.searchEngine);
    this.searchBaseUrl = SettingsPanel.draftBaseUrl(this.searchDraft, this.searchEngine);
    this.mmBaseUrl = this.initMmBaseUrl;
    this.mmApiKey = this.initMmApiKey;
    this.mmModel = this.initMmModel;
    this.mmPreparseEnabled = this.initMmPreparseEnabled;
  }

  build() {
    Stack() {
      // 遮罩常驻，只改变透明度，避免打开时与复杂表单同时创建。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.modal_backdrop'))
        .opacity(this.visible ? 1 : 0)
        .animation({ duration: 180, curve: Curve.EaseOut })
        .onClick(() => {
          if (this.visible) {
            this.onClose();
          }
        })

      // 表单常驻在屏幕下方，打开时只做合成层平移。
      Column() {
          // 标题
          Row() {
            Text('API 配置')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Button() {
              Text('✕')
                .fontSize(16)
                .fontColor($r('app.color.text_secondary'))
            }
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('app.color.raised_surface'))
            .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 2 })
            .onClick(() => {
              this.onClose();
            })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 18, bottom: 14 })
          .alignItems(VerticalAlign.Center)

          // 主体 (可滚动)
          Scroll() {
            Column() {
              this.buildSectionHeader('配置方案')
              Row() {
                Select(this.getProfileOptions())
                  .selected(this.selectedProfileIndex)
                  .value(this.initProfileName)
                  .fontColor($r('app.color.text_primary'))
                  .selectedOptionBgColor($r('app.color.brand_light'))
                  .selectedOptionFontColor($r('app.color.brand'))
                  .optionBgColor($r('app.color.surface'))
                  .optionFontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .height(44)
                  .borderRadius(14)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .onSelect((index: number) => {
                    this.onSelectProfile(index);
                  })

                Button() {
                  SymbolGlyph($r('sys.symbol.plus'))
                    .fontSize(18)
                    .fontColor([$r('app.color.brand')])
                }
                .width(44)
                .height(44)
                .borderRadius(14)
                .backgroundColor($r('app.color.brand_light'))
                .margin({ left: 8 })
                .onClick(() => {
                  this.onAddProfile();
                })
              }
              .width('100%')

              this.buildSectionHeader('配置名称')
              TextInput({ placeholder: '例如：DeepSeek V4', text: this.profileName })
                .width('100%')
                .height(44)
                .borderRadius(16)
                .backgroundColor($r('app.color.surface_secondary'))
                .padding({ left: 12, right: 12 })
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_secondary'))
                .onChange((value: string) => {
                  this.profileName = value;
                })

              this.buildSectionHeader('接入方式')
              Select([
                { value: 'openai-completions' },
                { value: 'openai-responses' },
                { value: 'anthropic-messages' }
              ])
                .selected(this.getProviderIndex())
                .value(this.getProviderLabel())
                .fontColor($r('app.color.text_primary'))
                .selectedOptionBgColor($r('app.color.brand_light'))
                .selectedOptionFontColor($r('app.color.brand'))
                .optionBgColor($r('app.color.surface'))
                .optionFontColor($r('app.color.text_primary'))
                .width('100%')
                .height(44)
                .borderRadius(16)
                .backgroundColor($r('app.color.surface_secondary'))
                .onSelect((index: number) => {
                  if (index === 0) {
                    this.provider = 'openai-completions';
                  } else if (index === 1) {
                    this.provider = 'openai-responses';
                  } else if (index === 2) {
                    this.provider = 'anthropic-messages';
                  }
                })

              this.buildSectionHeader('Base URL')
              TextInput({ placeholder: this.getBaseUrlPlaceholder(), text: this.baseUrl })
                .width('100%')
                .height(44)
                .borderRadius(16)
                .backgroundColor($r('app.color.surface_secondary'))
                .padding({ left: 12, right: 12 })
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_secondary'))
                .onChange((v: string) => {
                  this.baseUrl = v;
                })

              // 协议路径后缀补全开关: 关闭后严格按填写的 Base URL 发起请求
              Row() {
                Column() {
                  Text('自动补全 API 路径')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                  Text(this.autoSuffix ?
                    '开启后按接入方式自动拼接路径后缀：' + this.getSuffixExample() :
                    '已关闭补全：直接请求填写的 Base URL，适合非标准路径的网关。')
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                    .width('100%')
                    .lineHeight(18)
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.autoSuffix })
                  .selectedColor($r('app.color.brand'))
                  .onChange((enabled: boolean) => {
                    this.autoSuffix = enabled;
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ top: 10 })

              this.buildSectionHeader('API Key')
              TextInput({ placeholder: 'sk-...', text: this.apiKey })
                .type(InputType.Password)
                .width('100%')
                .height(44)
                .borderRadius(16)
                .backgroundColor($r('app.color.surface_secondary'))
                .padding({ left: 12, right: 12 })
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_secondary'))
                .onChange((v: string) => {
                  this.apiKey = v;
                })

              this.buildSectionHeader('模型名称 / Endpoint ID')
              TextInput({ placeholder: this.getModelPlaceholder(), text: this.model })
                .width('100%')
                .height(44)
                .borderRadius(16)
                .backgroundColor($r('app.color.surface_secondary'))
                .padding({ left: 12, right: 12 })
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_secondary'))
                .onChange((v: string) => {
                  this.model = v;
                })

              // 高级参数切换
              this.buildAdvancedSection()

              // 本地联网搜索(手机直连)
              this.buildSearchSection()

              // 多模态切换
              this.buildMultimodalSection()

              // 提示
              Text(this.getHint())
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(18)
                .width('100%')
                .margin({ top: 8 })

              // 保存按钮
              Button() {
                Text('保存配置')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
              }
              .width('100%')
              .height(50)
              .borderRadius(18)
              .backgroundColor($r('app.color.brand'))
              .margin({ top: 20, bottom: 24 })
              .onClick(() => {
                this.onSave(this.profileName, this.buildConfig(), this.buildMmConfig(),
                  this.buildSearchConfig());
              })
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 4, bottom: 24 })
          }
          .layoutWeight(1)
      }
      .width('100%')
      .height('92%')
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: 30, topRight: 30 })
      .shadow({ radius: 28, color: '#1F000000', offsetX: 0, offsetY: -6 })
      .position({ x: 0, y: '100%' })
      .translate({ y: this.visible ? '-100%' : '0%' })
      .opacity(this.visible ? 1 : 0)
      .animation({ duration: 260, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(this.visible ? 10 : -1)
    .hitTestBehavior(this.visible ? HitTestMode.Default : HitTestMode.None)
  }

  @Builder
  buildSectionHeader(label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  private getProfileOptions(): SelectOption[] {
    let options: SelectOption[] = [];
    for (let i: number = 0; i < this.profileNames.length; i++) {
      options.push({ value: this.profileNames[i] });
    }
    return options;
  }

  @Builder
  buildAdvancedSection() {
    Column() {
      Row() {
        Text('高级模型参数')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.advancedOpen ? '▲' : '▼')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .margin({ top: 12 })
      .onClick(() => {
        this.advancedOpen = !this.advancedOpen;
      })

      if (this.advancedOpen) {
        Column() {
          this.buildSectionHeader('Temperature')
          TextInput({ placeholder: '例如 0.7', text: this.temperature })
            .width('100%')
            .height(44)
            .borderRadius(16)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .onChange((v: string) => {
              this.temperature = v;
            })
          Text('数值越低回答越确定, 越高越随机。')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4 })

          this.buildSectionHeader('Top P')
          TextInput({ placeholder: '0.9', text: this.topP })
            .width('100%')
            .height(44)
            .borderRadius(16)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .onChange((v: string) => {
              this.topP = v;
            })

          this.buildSectionHeader('Max Tokens')
          TextInput({ placeholder: '留空默认 128000', text: this.maxTokens })
            .width('100%')
            .height(44)
            .borderRadius(16)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .onChange((v: string) => {
              this.maxTokens = v;
            })

          this.buildSectionHeader('额外请求参数 (JSON)')
          TextArea({ placeholder: '{"presence_penalty": 0, "frequency_penalty": 0}', text: this.extraBody })
            .width('100%')
            .height(80)
            .borderRadius(16)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .fontSize(13)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .onChange((v: string) => {
              this.extraBody = v;
            })
          Text('会合并到请求体中, 适合自定义 provider 专属参数。')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 4 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildMultimodalSection() {
    Column() {
      Row() {
        Text('多模态解析 API (可选)')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.multimodalOpen ? '▲' : '▼')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .margin({ top: 12 })
      .onClick(() => {
        this.multimodalOpen = !this.multimodalOpen;
      })

      if (this.multimodalOpen) {
        Column() {
          Row() {
            Column() {
              Text('先行解析附件')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(this.mmPreparseEnabled ?
                '开启后先由下方独立 API 解析，再将文本交给主模型。' :
                '关闭后图片和文档将直接传给当前接入方式的主模型。')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .lineHeight(18)
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.mmPreparseEnabled })
              .selectedColor($r('app.color.brand'))
              .onChange((enabled: boolean) => {
                this.mmPreparseEnabled = enabled;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 12, top: 4 })

          Text('默认使用 GLM-4.6V-Flash（免费API调用，请在智谱官网获取API Key），推荐使用 Doubao-Seed-2.0-mini 等轻量多模态模型。')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(18)
            .margin({ bottom: 12 })

          if (this.mmPreparseEnabled) {
            this.buildSectionHeader('Base URL')
            TextInput({ placeholder: 'https://open.bigmodel.cn/api/paas/v4', text: this.mmBaseUrl })
              .width('100%')
              .height(44)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .onChange((v: string) => {
                this.mmBaseUrl = v;
              })

            this.buildSectionHeader('API Key')
            TextInput({ placeholder: '...', text: this.mmApiKey })
              .type(InputType.Password)
              .width('100%')
              .height(44)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .onChange((v: string) => {
                this.mmApiKey = v;
              })

            this.buildSectionHeader('模型名称')
            TextInput({ placeholder: 'glm-4.6v-flash', text: this.mmModel })
              .width('100%')
              .height(44)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .onChange((v: string) => {
                this.mmModel = v;
              })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildSearchSection() {
    Column() {
      Row() {
        Text('本地联网搜索（手机直连）')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.searchOpen ? '▲' : '▼')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .margin({ top: 12 })
      .onClick(() => {
        this.searchOpen = !this.searchOpen;
      })

      if (this.searchOpen) {
        Column() {
          Text('内置 search_web 工具：是否搜索由模型自行决定，手机本地直连搜索引擎/搜索 API，' +
            '与"服务端联网搜索"开关互不影响、可同时存在。')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(18)
            .margin({ bottom: 8 })

          this.buildSectionHeader('搜索引擎')
          Select(this.getSearchEngineOptions())
            .selected(this.getSearchEngineIndex())
            .value(searchEngineLabel(this.searchEngine))
            .fontColor($r('app.color.text_primary'))
            .selectedOptionBgColor($r('app.color.brand_light'))
            .selectedOptionFontColor($r('app.color.brand'))
            .optionBgColor($r('app.color.surface'))
            .optionFontColor($r('app.color.text_primary'))
            .width('100%')
            .height(44)
            .borderRadius(16)
            .backgroundColor($r('app.color.surface_secondary'))
            .onSelect((index: number) => {
              this.onSearchEngineSelect(index);
            })

          if (searchEngineNeedsApiKey(this.searchEngine)) {
            this.buildSectionHeader('API Key')
            TextInput({ placeholder: '当前搜索引擎的 API Key', text: this.searchApiKey })
              .type(InputType.Password)
              .width('100%')
              .height(44)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .onChange((v: string) => {
                this.searchApiKey = v;
              })
          }

          if (searchEngineSupportsBaseUrl(this.searchEngine)) {
            this.buildSectionHeader('Base URL（可选）')
            TextInput({ placeholder: '留空使用默认地址', text: this.searchBaseUrl })
              .width('100%')
              .height(44)
              .borderRadius(16)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .onChange((v: string) => {
                this.searchBaseUrl = v;
              })
          }

          Text(this.getSearchEngineHint())
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .lineHeight(18)
            .margin({ top: 4 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private getSearchEngineOptions(): SelectOption[] {
    let options: SelectOption[] = [];
    let ids: string[] = this.searchEngineIds;
    for (let i: number = 0; i < ids.length; i++) {
      options.push({ value: searchEngineLabel(ids[i]) });
    }
    return options;
  }

  private getSearchEngineIndex(): number {
    let idx: number = this.searchEngineIds.indexOf(this.searchEngine);
    return idx >= 0 ? idx : 0;
  }

  // 切换引擎: 先把可见字段写回草稿(不丢已填的其他引擎配置), 再加载新引擎字段
  private onSearchEngineSelect(index: number): void {
    let ids: string[] = this.searchEngineIds;
    if (index < 0 || index >= ids.length) {
      return;
    }
    this.applySearchFieldsToDraft();
    this.searchEngine = ids[index];
    this.searchApiKey = this.searchDraft.apiKeyForEngine(this.searchEngine);
    this.searchBaseUrl = SettingsPanel.draftBaseUrl(this.searchDraft, this.searchEngine);
  }

  private applySearchFieldsToDraft(): void {
    let engine: string = this.searchEngine;
    let key: string = this.searchApiKey.trim();
    let base: string = this.searchBaseUrl.trim();
    if (engine === SEARCH_ENGINE_BRAVE) {
      this.searchDraft.braveApiKey = key;
    } else if (engine === SEARCH_ENGINE_TAVILY) {
      this.searchDraft.tavilyApiKey = key;
      if (base !== '') {
        this.searchDraft.tavilyBaseUrl = base;
      }
    } else if (engine === SEARCH_ENGINE_EXA) {
      this.searchDraft.exaApiKey = key;
      if (base !== '') {
        this.searchDraft.exaBaseUrl = base;
      }
    } else if (engine === SEARCH_ENGINE_METASO) {
      this.searchDraft.metasoApiKey = key;
    } else if (engine === SEARCH_ENGINE_FIRECRAWL) {
      this.searchDraft.firecrawlApiKey = key;
      if (base !== '') {
        this.searchDraft.firecrawlBaseUrl = base;
      }
    }
  }

  private static draftBaseUrl(cfg: SearchEngineSettings, engine: string): string {
    if (engine === SEARCH_ENGINE_TAVILY) {
      return cfg.tavilyBaseUrl;
    }
    if (engine === SEARCH_ENGINE_EXA) {
      return cfg.exaBaseUrl;
    }
    if (engine === SEARCH_ENGINE_FIRECRAWL) {
      return cfg.firecrawlBaseUrl;
    }
    return '';
  }

  private buildSearchConfig(): SearchEngineSettings {
    this.applySearchFieldsToDraft();
    this.searchDraft.engine = this.searchEngine;
    return this.searchDraft;
  }

  private getSearchEngineHint(): string {
    if (this.searchEngine === SEARCH_ENGINE_BING) {
      return 'Bing 无需 API Key, 直接爬取搜索结果页; 请求失败自动回落 cn.bing.com。';
    }
    if (this.searchEngine === SEARCH_ENGINE_TAVILY) {
      return '默认 Base URL: https://api.tavily.com';
    }
    if (this.searchEngine === SEARCH_ENGINE_EXA) {
      return '默认 Base URL: https://api.exa.ai';
    }
    if (this.searchEngine === SEARCH_ENGINE_FIRECRAWL) {
      return '默认 Base URL: https://api.firecrawl.dev';
    }
    if (this.searchEngine === SEARCH_ENGINE_METASO) {
      return '密钥在 metaso.cn 开放平台获取, 端点固定为 metaso.cn/api/v1/search。';
    }
    return '在对应平台获取 API Key 后填入。';
  }

  private getProviderIndex(): number {
    if (this.provider === 'openai-completions') {
      return 0;
    }
    if (this.provider === 'openai-responses') {
      return 1;
    }
    if (this.provider === 'anthropic-messages') {
      return 2;
    }
    return 0;
  }

  private getProviderLabel(): string {
    if (this.provider === 'openai-completions') {
      return 'openai-completions';
    }
    if (this.provider === 'openai-responses') {
      return 'openai-responses';
    }
    if (this.provider === 'anthropic-messages') {
      return 'anthropic-messages';
    }
    return '';
  }

  private getBaseUrlPlaceholder(): string {
    if (this.provider === 'openai-completions') {
      return 'https://api.openai.com/v1 或 https://api.deepseek.com';
    }
    if (this.provider === 'openai-responses') {
      return 'https://api.deepseek.com 或 https://ark.cn-beijing.volces.com/api/v3';
    }
    if (this.provider === 'anthropic-messages') {
      return 'https://api.anthropic.com/v1 或 https://api.deepseek.com';
    }
    return 'https://api.example.com/v1';
  }

  private getModelPlaceholder(): string {
    if (this.provider === 'openai-completions') {
      return 'deepseek-chat / deepseek-reasoner / gpt-...';
    }
    if (this.provider === 'openai-responses') {
      return 'deepseek-v4-flash / deepseek-v4-pro / ep-xxx';
    }
    if (this.provider === 'anthropic-messages') {
      return 'deepseek-v4-pro / deepseek-v4-flash / claude-...';
    }
    return 'model-name';
  }

  private getHint(): string {
    if (this.provider === 'openai-completions') {
      return '当前接入方式：OpenAI Completions，通用API接入方式，兼容大部分模型。若需要原生图片直传、联网搜索等能力，建议切换 Responses API 或 Anthropic API 选项（需查询模型支持的方式）';
    }
    if (this.provider === 'openai-responses') {
      return '当前接入方式：OpenAI Responses， 建议支持 Responses API 的模型优先选择此选项，以获得原生图片直传、联网搜索等能力';
    }
    if (this.provider === 'anthropic-messages') {
      return '当前接入方式：Anthropic Messages，建议支持 Anthropic API 的模型优先选择此选项，以获得原生图片直传、联网搜索等能力';
    }
    return 'OpenAI Completions: 填写完整的 Base URL、API Key 与模型名称。';
  }

  private getSuffixExample(): string {
    if (this.provider === 'openai-completions') {
      return '/chat/completions';
    }
    if (this.provider === 'openai-responses') {
      return '/responses';
    }
    if (this.provider === 'anthropic-messages') {
      return '/v1/messages 或 /anthropic/v1/messages ';
    }
    return '填写完整的 Base URL、API Key 与模型名称。';
  }

  private buildConfig(): ApiConfig {
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = this.provider;
    cfg.baseUrl = this.baseUrl.trim();
    cfg.apiKey = this.apiKey.trim();
    cfg.model = this.model.trim();
    cfg.extraBody = this.extraBody.trim();
    cfg.temperature = this.temperature !== '' ? parseFloat(this.temperature) : null;
    cfg.topP = this.topP !== '' ? parseFloat(this.topP) : null;
    cfg.maxTokens = this.maxTokens !== '' ? parseInt(this.maxTokens) : null;
    cfg.autoSuffix = this.autoSuffix;
    return cfg;
  }

  private buildMmConfig(): MultimodalConfig {
    let cfg: MultimodalConfig = MultimodalConfig.default();
    if (this.mmBaseUrl.trim() !== '') {
      cfg.baseUrl = this.mmBaseUrl.trim();
    }
    cfg.apiKey = this.mmApiKey.trim();
    if (this.mmModel.trim() !== '') {
      cfg.model = this.mmModel.trim();
    }
    cfg.preparseEnabled = this.mmPreparseEnabled;
    return cfg;
  }
}
