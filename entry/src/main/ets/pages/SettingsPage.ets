import { router, promptAction } from '@kit.ArkUI';
import { ApiConfig } from '../model/ApiConfig';
import { ApiProfile } from '../model/ApiProfile';
import { MultimodalConfig } from '../model/MultimodalConfig';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SettingsSession } from '../viewmodel/SettingsSession';
import { SearchEngineSettings, SEARCH_ENGINE_BING, SEARCH_ENGINE_BRAVE, SEARCH_ENGINE_TAVILY,
  SEARCH_ENGINE_EXA, SEARCH_ENGINE_METASO, SEARCH_ENGINE_FIRECRAWL,
  searchEngineNeedsApiKey, searchEngineSupportsBaseUrl, searchEngineLabel } from '../service/LocalWebSearch';

// 设置页: 独立路由页, 用"设置首页 + 分项详情"的两级结构替代原来的底部弹层。
// 每一块配置都是独立选项, 点进去只编辑这一块; 草稿在所有分页之间共享,
// 修改后自动防抖保存, 避免一页里堆叠多个折叠框, 也不用手动点保存。
@Entry
@Component
struct SettingsPage {
  // 聊天页注入的 ViewModel(与聊天页共享, 保存后立即生效)
  private vm: ChatViewModel | null = null;

  // 当前页面: root / model / advanced / search / multimodal
  @State private view: string = 'root';

  // 自动保存: 修改后防抖落盘, 不阻塞输入; 切方案/离开页面前强制排队一次
  private autoSaveTimer: number = -1;
  private saveChain: Promise<void> = Promise.resolve();
  private editVersion: number = 0;
  private queuedVersion: number = 0;
  private savedVersion: number = 0;

  // 配置方案快照(VM 内部数组不受本页状态观察, 每次增删/切换后重新取一份)
  @State private profiles: ApiProfile[] = [];
  @State private currentProfileId: string = '';

  // 模型配置草稿
  @State private profileName: string = '默认配置';
  @State private provider: string = 'openai-completions';
  @State private baseUrl: string = '';
  @State private apiKey: string = '';
  @State private model: string = '';
  @State private models: string[] = [];
  // 模型列表增删行时递增, 让 ForEach 按下标整体重建输入框
  @State private modelFormTick: number = 0;

  // 高级参数草稿
  @State private temperature: string = '';
  @State private topP: string = '';
  @State private maxTokens: string = '';
  @State private extraBody: string = '';
  @State private autoSuffix: boolean = true;

  // 多模态解析草稿
  @State private mmBaseUrl: string = '';
  @State private mmApiKey: string = '';
  @State private mmModel: string = '';
  @State private mmPreparseEnabled: boolean = false;
  @State private mmPreparseUserSet: boolean = false;

  // 本地联网搜索草稿(当前引擎的可见字段 + 全量草稿)
  @State private searchEngine: string = SEARCH_ENGINE_BING;
  @State private searchApiKey: string = '';
  @State private searchBaseUrl: string = '';
  @State private searchMaxResults: string = '8';
  private searchDraft: SearchEngineSettings = new SearchEngineSettings();
  private searchEngineIds: string[] = [
    SEARCH_ENGINE_BING, SEARCH_ENGINE_BRAVE, SEARCH_ENGINE_TAVILY,
    SEARCH_ENGINE_EXA, SEARCH_ENGINE_METASO, SEARCH_ENGINE_FIRECRAWL
  ];

  aboutToAppear(): void {
    this.vm = SettingsSession.current();
    if (this.vm === null) {
      // 进程恢复等极端情况下没有聊天页 VM: 直接返回, 避免操作空对象
      setTimeout((): void => {
        router.back();
      }, 0);
      return;
    }
    this.syncFromVm();
  }

  // 把 VM 里的当前方案完整同步到本页草稿(打开设置、切换方案、增删方案后调用)
  private syncFromVm(): void {
    let vm: ChatViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    this.cancelAutoSave();
    this.profiles = vm.apiProfiles.slice();
    this.currentProfileId = vm.currentApiProfileId;

    let profile: ApiProfile | null = vm.currentApiProfile;
    this.profileName = profile !== null ? profile.name : '默认配置';

    let cfg: ApiConfig = vm.apiConfig;
    this.provider = cfg.provider;
    this.baseUrl = cfg.baseUrl;
    this.apiKey = cfg.apiKey;
    this.model = cfg.model;
    let names: string[] = cfg.modelList();
    this.models = names.length > 0 ? names : [''];
    this.modelFormTick++;
    this.temperature = cfg.temperature !== null ? cfg.temperature.toString() : '';
    this.topP = cfg.topP !== null ? cfg.topP.toString() : '';
    this.maxTokens = cfg.maxTokens !== null ? cfg.maxTokens.toString() : '';
    this.extraBody = cfg.extraBody;
    this.autoSuffix = cfg.autoSuffix;

    this.mmBaseUrl = vm.multimodalConfig.baseUrl;
    this.mmApiKey = vm.multimodalConfig.apiKey;
    this.mmModel = vm.multimodalConfig.model;
    this.mmPreparseEnabled = vm.multimodalConfig.preparseEnabled;
    this.mmPreparseUserSet = vm.multimodalConfig.preparseUserSet;

    // 深拷贝一份搜索配置, 避免编辑过程中直接改动 VM 持有对象
    this.searchDraft = SearchEngineSettings.parse(JSON.stringify(vm.localSearchConfig.toJson()));
    this.searchEngine = this.searchDraft.engine;
    this.searchApiKey = this.searchDraft.apiKeyForEngine(this.searchEngine);
    this.searchBaseUrl = this.draftBaseUrl(this.searchEngine);
    this.searchMaxResults = this.searchDraft.maxResults.toString();
  }

  build() {
    Column() {
      this.buildHeader()
      if (this.view === 'model') {
        this.buildModelView()
      } else if (this.view === 'advanced') {
        this.buildAdvancedView()
      } else if (this.view === 'search') {
        this.buildSearchView()
      } else if (this.view === 'multimodal') {
        this.buildMultimodalView()
      } else {
        this.buildRootView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.sidebar_fill'))
  }

  @Builder
  private buildHeader() {
    Column() {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.handleBack();
        })

        Text(this.viewTitle())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .height(56)
      .padding({ left: 10, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(56)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.background'))
    .border({ width: { bottom: 0.5 }, color: { bottom: $r('app.color.divider') } })
  }

  // ===== 设置首页 =====
  @Builder
  private buildRootView() {
    Scroll() {
      Column() {
        Column() {
          this.buildSectionLabel('模型')
          Column() {
            this.buildOptionRow($r('sys.symbol.rectangle_stack'), '模型配置',
              this.modelSummary(), (): void => {
                this.view = 'model';
              })
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 56 })
            this.buildOptionRow($r('sys.symbol.wrench_and_screwdriver'), '高级参数',
              this.advancedSummary(), (): void => {
                this.view = 'advanced';
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.divider') })
          .clip(true)

          this.buildSectionLabel('能力')
          Column() {
            this.buildOptionRow($r('sys.symbol.magnifyingglass'), '本地联网搜索',
              this.searchSummary(), (): void => {
                this.view = 'search';
              })
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ left: 56 })
            this.buildOptionRow($r('sys.symbol.picture'), '多模态解析',
              this.multimodalSummary(), (): void => {
                this.view = 'multimodal';
              })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.divider') })
          .clip(true)
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private buildSectionLabel(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 4 })
      .margin({ top: 12, bottom: 8 })
  }

  @Builder
  private buildOptionRow(icon: Resource, title: string, subtitle: string, onTap: () => void) {
    Row() {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(23)
          .fontColor([$r('app.color.brand')])
      }
      .width(28)
      .height(40)
      .backgroundColor(Color.Transparent)

      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14 })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor([$r('app.color.text_quaternary')])
    }
    .width('100%')
    .height(68)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      onTap();
    })
  }

  // ===== 模型配置 =====
  @Builder
  private buildModelView() {
    Scroll() {
      Column() {
        this.buildSectionLabel('配置方案')
        Column() {
          ForEach(this.profiles, (profile: ApiProfile, index: number) => {
            Row() {
              Column() {
                if (profile.id === this.currentProfileId) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(20)
                    .fontColor([$r('app.color.brand')])
                } else {
                  Column()
                    .width(18)
                    .height(18)
                    .borderRadius(9)
                    .border({ width: 1.5, color: $r('app.color.text_quaternary') })
                }
              }
              .width(24)
              .alignItems(HorizontalAlign.Center)

              Column() {
                Row() {
                  Text(profile.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (profile.builtin) {
                    Text('内置')
                      .fontSize(10)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(8)
                      .backgroundColor($r('app.color.surface'))
                      .margin({ left: 6 })
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Text(this.profileSubtitle(profile))
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 10 })
            }
            .width('100%')
            .padding({ left: 10, right: 12, top: 10, bottom: 10 })
            .borderRadius(14)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(profile.id === this.currentProfileId ?
              $r('app.color.brand_light') : Color.Transparent)
            .onClick(() => {
              this.selectProfile(index);
            })
          }, (profile: ApiProfile) => profile.id + '|' + profile.name + '|' +
            profile.apiConfig.model + '|' + (profile.builtin ? '1' : '0'))

          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.divider'))
            .margin({ left: 12, right: 12, top: 4, bottom: 4 })

          Row() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(16)
              .fontColor([$r('app.color.brand')])
            Text('新建配置')
              .fontSize(14)
              .fontColor($r('app.color.brand'))
              .margin({ left: 6 })
            Blank()
          }
          .width('100%')
          .height(46)
          .padding({ left: 14, right: 14 })
          .borderRadius(14)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.addProfile();
          })
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })

        if (!this.currentProfileBuiltin()) {
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(18)
                .fontColor([$r('app.color.danger')])
              Text('删除当前配置')
                .fontSize(14)
                .fontColor($r('app.color.danger'))
                .margin({ left: 8 })
              Blank()
            }
            .width('100%')
            .height(52)
            .padding({ left: 16, right: 16 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.deleteProfile();
            })
          }
          .width('100%')
          .margin({ top: 10 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(18)
          .border({ width: 1, color: $r('app.color.divider') })
        }

        this.buildSectionLabel('配置名称')
        Column() {
          TextInput({ placeholder: '例如：DeepSeek V4', text: this.profileName })
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.profileName = value;
              this.onDraftChanged();
            })
          Text('用于在模型选择器中区分不同的配置方案。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })

        this.buildSectionLabel('接入与密钥')
        Column() {
          Text('接入协议')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          Select(this.getProviderOptions())
            .selected(this.getProviderIndex())
            .value(this.getProviderLabel())
            .fontColor($r('app.color.text_primary'))
            .selectedOptionBgColor($r('app.color.brand_light'))
            .selectedOptionFontColor($r('app.color.brand'))
            .optionBgColor($r('app.color.surface'))
            .optionFontColor($r('app.color.text_primary'))
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .onSelect((index: number) => {
              this.onProviderSelect(index);
            })
          Text(this.getProviderHint())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.divider'))
            .margin({ top: 16, bottom: 16 })

          Text('Base URL')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          TextInput({ placeholder: this.getBaseUrlPlaceholder(), text: this.baseUrl })
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.baseUrl = value;
              this.onDraftChanged();
            })

          Row() {
            Column() {
              Text('自动补全 API 路径')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(this.autoSuffix ?
                '开启后自动拼接 ' + this.getSuffixExample() :
                '已关闭：直接请求填写的 Base URL，适合非标准路径的网关。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .lineHeight(17)
                .margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.autoSuffix })
              .selectedColor($r('app.color.brand'))
              .onChange((enabled: boolean) => {
                this.autoSuffix = enabled;
                this.onDraftChanged();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 14 })

          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.divider'))
            .margin({ top: 16, bottom: 16 })

          Text('API Key')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          TextInput({ placeholder: 'sk-...', text: this.apiKey })
            .type(InputType.Password)
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.apiKey = value;
              this.onDraftChanged();
            })
          Text('仅保存在本机，不会上传到服务器。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })

        this.buildSectionLabel('模型名称')
        Column() {
          ForEach(this.models, (name: string, index: number) => {
            Row() {
              TextInput({ placeholder: this.getModelPlaceholder(), text: name })
                .layoutWeight(1)
                .height(46)
                .borderRadius(14)
                .backgroundColor($r('app.color.surface_secondary'))
                .padding({ left: 12, right: 12 })
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .onChange((value: string) => {
                  this.updateModelName(index, value);
                })
              if (this.models.length > 1) {
                Button() {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(16)
                    .fontColor([$r('app.color.text_tertiary')])
                }
                .width(36)
                .height(46)
                .borderRadius(12)
                .backgroundColor(Color.Transparent)
                .margin({ left: 4 })
                .onClick(() => {
                  this.removeModelName(index);
                })
              }
            }
            .width('100%')
            .margin({ top: 8 })
            .alignItems(VerticalAlign.Center)
          }, (name: string, index: number) =>
            this.modelFormTick.toString() + '-' + index.toString())

          Row() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(14)
              .fontColor([$r('app.color.brand')])
            Text('添加模型')
              .fontSize(13)
              .fontColor($r('app.color.brand'))
              .margin({ left: 4 })
          }
          .height(42)
          .padding({ left: 12, right: 12 })
          .borderRadius(14)
          .backgroundColor($r('app.color.brand_light'))
          .alignItems(VerticalAlign.Center)
          .margin({ top: 10 })
          .onClick(() => {
            this.addModelName();
          })

          Text('可填写多个模型名称：模型选择器会逐个列出，当前使用的模型在对话页切换。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 10 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 32 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 16, right: 16 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ===== 高级参数 =====
  @Builder
  private buildAdvancedView() {
    Scroll() {
      Column() {
        this.buildSectionLabel('生成参数')
        Column() {
          Text('Temperature')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          TextInput({ placeholder: '例如 0.7', text: this.temperature })
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.temperature = value;
              this.onDraftChanged();
            })
          Text('数值越低回答越确定，越高越随机。留空使用服务端默认值。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.divider'))
            .margin({ top: 16, bottom: 16 })

          Text('Top P')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          TextInput({ placeholder: '例如 0.9', text: this.topP })
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.topP = value;
              this.onDraftChanged();
            })
          Text('与 Temperature 类似，通常只调整其中一个。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.divider'))
            .margin({ top: 16, bottom: 16 })

          Text('Max Tokens')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          TextInput({ placeholder: '留空默认 128000', text: this.maxTokens })
            .type(InputType.Number)
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.maxTokens = value;
              this.onDraftChanged();
            })
          Text('单次回复的最大输出长度，思考内容同样计入额度。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })

        this.buildSectionLabel('额外请求参数')
        Column() {
          TextArea({ placeholder: '{"presence_penalty": 0, "frequency_penalty": 0}',
            text: this.extraBody })
            .width('100%')
            .height(112)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .fontSize(13)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.extraBody = value;
              this.onDraftChanged();
            })
          Text('JSON 对象会合并到请求体中，适合自定义 provider 专属参数。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 32 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 16, right: 16 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ===== 本地联网搜索 =====
  @Builder
  private buildSearchView() {
    Scroll() {
      Column() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(16)
              .fontColor([$r('app.color.brand')])
            Text('内置 local_web_search 工具：手机直连搜索引擎，作为服务端搜索的兜底通道。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .lineHeight(18)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ top: 16 })

        this.buildSectionLabel('搜索引擎')
        Column() {
          Text('搜索服务')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 8 })
          Select(this.getSearchEngineOptions())
            .selected(this.getSearchEngineIndex())
            .value(searchEngineLabel(this.searchEngine))
            .fontColor($r('app.color.text_primary'))
            .selectedOptionBgColor($r('app.color.brand_light'))
            .selectedOptionFontColor($r('app.color.brand'))
            .optionBgColor($r('app.color.surface'))
            .optionFontColor($r('app.color.text_primary'))
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .onSelect((index: number) => {
              this.onSearchEngineSelect(index);
            })
          Text(this.getSearchEngineHint())
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })

          if (searchEngineNeedsApiKey(this.searchEngine)) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 16, bottom: 16 })
            Text('API Key')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 8 })
            TextInput({ placeholder: '当前搜索引擎的 API Key', text: this.searchApiKey })
              .type(InputType.Password)
              .width('100%')
              .height(46)
              .borderRadius(14)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.searchApiKey = value;
                this.onDraftChanged();
              })
          }

          if (searchEngineSupportsBaseUrl(this.searchEngine)) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 16, bottom: 16 })
            Text('Base URL（可选）')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 8 })
            TextInput({ placeholder: '留空使用默认地址', text: this.searchBaseUrl })
              .width('100%')
              .height(46)
              .borderRadius(14)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.searchBaseUrl = value;
                this.onDraftChanged();
              })
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })

        this.buildSectionLabel('单次结果条数')
        Column() {
          TextInput({ placeholder: '8', text: this.searchMaxResults })
            .type(InputType.Number)
            .width('100%')
            .height(46)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface_secondary'))
            .padding({ left: 12, right: 12 })
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.searchMaxResults = value;
              this.onDraftChanged();
            })
          Text('每次 local_web_search 取回 1~20 条结果。条数越多上下文越挤，手机上 5~8 条通常够用。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .lineHeight(17)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ bottom: 32 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 16, right: 16 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ===== 多模态解析 =====
  @Builder
  private buildMultimodalView() {
    Scroll() {
      Column() {
        Column() {
          Row() {
            Column() {
              Text('先行解析附件')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(this.mmPreparseEnabled ?
                '开启后先由下方独立 API 解析，再将文本交给主模型。' :
                '关闭后图片和文档直接传给当前接入方式的主模型。')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .lineHeight(17)
                .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.mmPreparseEnabled })
              .selectedColor($r('app.color.brand'))
              .onChange((enabled: boolean) => {
                this.mmPreparseEnabled = enabled;
                this.mmPreparseUserSet = true;
                this.onDraftChanged();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(22)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ top: 16 })

        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(16)
              .fontColor([$r('app.color.brand')])
            Text('默认使用 GLM-4.6V-Flash（智谱免费 API，请在智谱官网获取 Key），' +
              '也推荐 Doubao-Seed-2.0-mini 等轻量多模态模型。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .lineHeight(18)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .padding(14)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(18)
        .border({ width: 1, color: $r('app.color.divider') })
        .margin({ top: 10 })

        if (this.mmPreparseEnabled) {
          this.buildSectionLabel('解析 API')
          Column() {
            Text('Base URL')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 8 })
            TextInput({ placeholder: 'https://open.bigmodel.cn/api/paas/v4', text: this.mmBaseUrl })
              .width('100%')
              .height(46)
              .borderRadius(14)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.mmBaseUrl = value;
                this.onDraftChanged();
              })

            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 16, bottom: 16 })

            Text('API Key')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 8 })
            TextInput({ placeholder: '...', text: this.mmApiKey })
              .type(InputType.Password)
              .width('100%')
              .height(46)
              .borderRadius(14)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.mmApiKey = value;
                this.onDraftChanged();
              })

            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.divider'))
              .margin({ top: 16, bottom: 16 })

            Text('模型名称')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 8 })
            TextInput({ placeholder: 'glm-4.6v-flash', text: this.mmModel })
              .width('100%')
              .height(46)
              .borderRadius(14)
              .backgroundColor($r('app.color.surface_secondary'))
              .padding({ left: 12, right: 12 })
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.mmModel = value;
                this.onDraftChanged();
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .border({ width: 1, color: $r('app.color.divider') })
        }

        Text('多模态解析配置会随当前配置方案一起保存。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 24, bottom: 32 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 16, right: 16 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ===== 页面标题 =====
  private viewTitle(): string {
    if (this.view === 'model') {
      return '模型配置';
    }
    if (this.view === 'advanced') {
      return '高级参数';
    }
    if (this.view === 'search') {
      return '本地联网搜索';
    }
    if (this.view === 'multimodal') {
      return '多模态解析';
    }
    return '设置';
  }

  // ===== 返回 / 自动保存 =====
  private handleBack(): void {
    if (this.view !== 'root') {
      this.view = 'root';
      return;
    }
    // 立即返回, 不等待写盘; 草稿已在 flushSave 里同步取好并排队, 后台继续完成
    this.flushSave();
    router.back();
  }

  onBackPress(): boolean {
    if (this.view !== 'root') {
      this.view = 'root';
      return true;
    }
    this.flushSave();
    return false;
  }

  // 任一字段变化后调用: 只记版本并启动 350ms 防抖, 不做任何会触发整页重绘的保存状态
  private onDraftChanged(): void {
    this.editVersion++;
    this.cancelAutoSave();
    this.autoSaveTimer = setTimeout((): void => {
      this.autoSaveTimer = -1;
      this.flushSave();
    }, 350);
  }

  private cancelAutoSave(): void {
    if (this.autoSaveTimer !== -1) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = -1;
    }
  }

  // 把当前草稿排队落盘。返回的 Promise 用于切换方案前等待, 确保旧方案先写完。
  private flushSave(): Promise<void> {
    this.cancelAutoSave();
    if (this.editVersion <= this.queuedVersion) {
      return this.saveChain;
    }
    return this.enqueueSave();
  }

  private enqueueSave(): Promise<void> {
    let targetVm: ChatViewModel | null = this.vm;
    if (targetVm === null || targetVm.currentApiProfile === null) {
      return this.saveChain;
    }
    let vm: ChatViewModel = targetVm;
    // 同步取好快照: 之后页面销毁、继续输入或切换方案都不会改变这次要写的内容
    let profileId: string = this.currentProfileId;
    let name: string = this.profileName;
    let api: ApiConfig = this.buildConfig();
    let mm: MultimodalConfig = this.buildMmConfig();
    let search: SearchEngineSettings = this.buildSearchConfig();
    let version: number = this.editVersion;
    this.queuedVersion = version;
    // 串行写: 避免多次 Preferences 写入互相覆盖, 也不会阻塞输入
    this.saveChain = this.saveChain.then(async (): Promise<void> => {
      await vm.saveLocalSearchConfig(search);
      await vm.saveApiProfile(profileId, name, api, mm);
      if (version > this.savedVersion) {
        this.savedVersion = version;
      }
    }).catch((): void => {
      // 自动保存失败不打断编辑; 下一次修改或离开页面会重新排队
      if (this.queuedVersion === version) {
        this.queuedVersion = this.savedVersion;
      }
    });
    return this.saveChain;
  }

  // ===== 配置方案操作 =====
  private selectProfile(index: number): void {
    let vm: ChatViewModel | null = this.vm;
    if (vm === null || index < 0 || index >= this.profiles.length) {
      return;
    }
    if (vm.isStreaming) {
      promptAction.showToast({ message: 'AI 正在回复中，暂不能切换配置', duration: 1600 });
      return;
    }
    let target: ApiProfile = this.profiles[index];
    if (target.id === this.currentProfileId) {
      return;
    }
    // 切换方案会换掉整份表单: 先把当前草稿按旧方案 id 排队, 切过去后后台继续写
    this.flushSave();
    // selectApiProfile 在第一个 await 之前就完成 applyApiProfile, 这里不等待写盘,
    // 表单立即切到新方案, 避免点一下卡半拍。
    vm.selectApiProfile(target.id).catch((): void => {});
    this.syncFromVm();
  }

  private async addProfile(): Promise<void> {
    let vm: ChatViewModel | null = this.vm;
    if (vm === null) {
      return;
    }
    if (vm.isStreaming) {
      promptAction.showToast({ message: 'AI 正在回复中，暂不能新建配置', duration: 1600 });
      return;
    }
    // 新建/删除会改方案列表, 先等排队中的写入完成, 避免两次列表写盘互相覆盖
    await this.flushSave();
    await vm.addApiProfile();
    this.syncFromVm();
  }

  private async deleteProfile(): Promise<void> {
    let vm: ChatViewModel | null = this.vm;
    if (vm === null || this.currentProfileId === '') {
      return;
    }
    if (vm.isStreaming) {
      promptAction.showToast({ message: 'AI 正在回复中，暂不能删除配置', duration: 1600 });
      return;
    }
    // 先等排队中的写入完成, 避免删除与列表写盘并发; 用户取消删除时草稿仍然保留
    await this.flushSave();
    let deleted: boolean = await vm.deleteApiProfile(this.currentProfileId);
    if (deleted) {
      this.syncFromVm();
    }
  }

  private currentProfileBuiltin(): boolean {
    for (let i: number = 0; i < this.profiles.length; i++) {
      if (this.profiles[i].id === this.currentProfileId) {
        return this.profiles[i].builtin;
      }
    }
    return true;
  }

  private profileSubtitle(profile: ApiProfile): string {
    let model: string = profile.apiConfig.model.trim();
    let modelLabel: string = model !== '' ? model : '未设置模型';
    return this.getProviderShortLabel(profile.apiConfig.provider) + ' · ' + modelLabel;
  }

  // ===== 首页摘要 =====
  private modelSummary(): string {
    let name: string = this.profileName.trim() !== '' ? this.profileName.trim() : '未命名配置';
    let model: string = this.model.trim() !== '' ? this.model.trim() : '未设置模型';
    return name + ' · ' + model;
  }

  private advancedSummary(): string {
    let parts: string[] = [];
    if (this.temperature.trim() !== '') {
      parts.push('Temperature ' + this.temperature.trim());
    }
    if (this.topP.trim() !== '') {
      parts.push('Top P ' + this.topP.trim());
    }
    if (this.maxTokens.trim() !== '') {
      parts.push('Max Tokens ' + this.maxTokens.trim());
    }
    if (this.extraBody.trim() !== '') {
      parts.push('自定义请求参数');
    }
    if (parts.length === 0) {
      return '使用模型默认参数';
    }
    return parts.join(' · ');
  }

  private searchSummary(): string {
    let n: number = parseInt(this.searchMaxResults, 10);
    if (isNaN(n)) {
      n = 8;
    }
    if (n < 1) {
      n = 1;
    }
    if (n > 20) {
      n = 20;
    }
    return searchEngineLabel(this.searchEngine) + ' · 每次 ' + n + ' 条';
  }

  private multimodalSummary(): string {
    if (!this.mmPreparseEnabled) {
      return '已关闭 · 附件直传主模型';
    }
    let model: string = this.mmModel.trim() !== '' ? this.mmModel.trim() : '默认模型';
    return '已开启 · ' + model;
  }

  // ===== 模型字段操作 =====
  private onProviderSelect(index: number): void {
    if (index === 0) {
      this.provider = 'openai-completions';
    } else if (index === 1) {
      this.provider = 'openai-responses';
    } else if (index === 2) {
      this.provider = 'anthropic-messages';
    }
    this.onDraftChanged();
  }

  private updateModelName(index: number, value: string): void {
    if (index < 0 || index >= this.models.length) {
      return;
    }
    let old: string = this.models[index].trim();
    if (old !== '' && this.model.trim() === old) {
      this.model = value;
    }
    let next: string[] = this.models.slice();
    next[index] = value;
    this.models = next;
    this.onDraftChanged();
  }

  private addModelName(): void {
    let next: string[] = this.models.slice();
    next.push('');
    this.models = next;
    this.modelFormTick++;
    this.onDraftChanged();
  }

  private removeModelName(index: number): void {
    if (this.models.length <= 1 || index < 0 || index >= this.models.length) {
      return;
    }
    let next: string[] = [];
    for (let i: number = 0; i < this.models.length; i++) {
      if (i !== index) {
        next.push(this.models[i]);
      }
    }
    this.models = next;
    this.modelFormTick++;
    this.onDraftChanged();
  }

  // ===== 搜索字段操作 =====
  private applySearchFieldsToDraft(): void {
    let engine: string = this.searchEngine;
    let key: string = this.searchApiKey.trim();
    let base: string = this.searchBaseUrl.trim();
    if (engine === SEARCH_ENGINE_BRAVE) {
      this.searchDraft.braveApiKey = key;
    } else if (engine === SEARCH_ENGINE_TAVILY) {
      this.searchDraft.tavilyApiKey = key;
      this.searchDraft.tavilyBaseUrl = base;
    } else if (engine === SEARCH_ENGINE_EXA) {
      this.searchDraft.exaApiKey = key;
      this.searchDraft.exaBaseUrl = base;
    } else if (engine === SEARCH_ENGINE_METASO) {
      this.searchDraft.metasoApiKey = key;
    } else if (engine === SEARCH_ENGINE_FIRECRAWL) {
      this.searchDraft.firecrawlApiKey = key;
      this.searchDraft.firecrawlBaseUrl = base;
    }
  }

  private draftBaseUrl(engine: string): string {
    if (engine === SEARCH_ENGINE_TAVILY) {
      return this.searchDraft.tavilyBaseUrl;
    }
    if (engine === SEARCH_ENGINE_EXA) {
      return this.searchDraft.exaBaseUrl;
    }
    if (engine === SEARCH_ENGINE_FIRECRAWL) {
      return this.searchDraft.firecrawlBaseUrl;
    }
    return '';
  }

  private onSearchEngineSelect(index: number): void {
    if (index < 0 || index >= this.searchEngineIds.length) {
      return;
    }
    // 先把可见字段写回草稿(不丢已填的其他引擎配置), 再加载新引擎字段
    this.applySearchFieldsToDraft();
    this.searchEngine = this.searchEngineIds[index];
    this.searchApiKey = this.searchDraft.apiKeyForEngine(this.searchEngine);
    this.searchBaseUrl = this.draftBaseUrl(this.searchEngine);
    this.onDraftChanged();
  }

  private getSearchEngineOptions(): SelectOption[] {
    let options: SelectOption[] = [];
    for (let i: number = 0; i < this.searchEngineIds.length; i++) {
      options.push({ value: searchEngineLabel(this.searchEngineIds[i]) });
    }
    return options;
  }

  private getSearchEngineIndex(): number {
    let index: number = this.searchEngineIds.indexOf(this.searchEngine);
    return index >= 0 ? index : 0;
  }

  private getSearchEngineHint(): string {
    if (this.searchEngine === SEARCH_ENGINE_BING) {
      return 'Bing 无需 API Key，直接解析搜索结果页；请求失败自动回落 cn.bing.com。';
    }
    if (this.searchEngine === SEARCH_ENGINE_TAVILY) {
      return '默认 Base URL：https://api.tavily.com';
    }
    if (this.searchEngine === SEARCH_ENGINE_EXA) {
      return '默认 Base URL：https://api.exa.ai';
    }
    if (this.searchEngine === SEARCH_ENGINE_FIRECRAWL) {
      return '默认 Base URL：https://api.firecrawl.dev';
    }
    if (this.searchEngine === SEARCH_ENGINE_METASO) {
      return '密钥在 metaso.cn 开放平台获取，端点固定为 metaso.cn/api/v1/search。';
    }
    return '在对应平台获取 API Key 后填入。';
  }

  // ===== 接入方式展示 =====
  private getProviderOptions(): SelectOption[] {
    return [
      { value: 'OpenAI Completions' },
      { value: 'OpenAI Responses' },
      { value: 'Anthropic Messages' }
    ];
  }

  private getProviderIndex(): number {
    if (this.provider === 'openai-responses') {
      return 1;
    }
    if (this.provider === 'anthropic-messages') {
      return 2;
    }
    return 0;
  }

  private getProviderLabel(): string {
    if (this.provider === 'openai-responses') {
      return 'OpenAI Responses';
    }
    if (this.provider === 'anthropic-messages') {
      return 'Anthropic Messages';
    }
    return 'OpenAI Completions';
  }

  private getProviderShortLabel(provider: string): string {
    if (provider === 'openai-responses') {
      return 'Responses';
    }
    if (provider === 'anthropic-messages') {
      return 'Anthropic';
    }
    return 'Completions';
  }

  private getProviderHint(): string {
    if (this.provider === 'openai-responses') {
      return '建议支持 Responses API 的模型优先选择，可获得原生图片直传与服务端联网搜索。';
    }
    if (this.provider === 'anthropic-messages') {
      return '建议支持 Anthropic Messages 的模型优先选择，可获得原生图片直传与服务端联网搜索。';
    }
    return '通用 Chat Completions 接口，兼容大部分模型服务。';
  }

  private getBaseUrlPlaceholder(): string {
    if (this.provider === 'openai-responses') {
      return 'https://api.deepseek.com 或 https://ark.cn-beijing.volces.com/api/v3';
    }
    if (this.provider === 'anthropic-messages') {
      return 'https://api.anthropic.com/v1 或 https://api.deepseek.com';
    }
    return 'https://api.openai.com/v1 或 https://api.deepseek.com';
  }

  private getModelPlaceholder(): string {
    if (this.provider === 'openai-responses') {
      return 'deepseek-v4-flash / deepseek-v4-pro / ep-xxx';
    }
    if (this.provider === 'anthropic-messages') {
      return 'deepseek-v4-pro / deepseek-v4-flash / claude-...';
    }
    return 'deepseek-chat / deepseek-reasoner / gpt-...';
  }

  private getSuffixExample(): string {
    if (this.provider === 'openai-responses') {
      return '/responses';
    }
    if (this.provider === 'anthropic-messages') {
      return '/v1/messages 或 /anthropic/v1/messages';
    }
    return '/chat/completions';
  }

  // ===== 构造持久化配置 =====
  private buildConfig(): ApiConfig {
    let cfg: ApiConfig = new ApiConfig();
    cfg.provider = this.provider;
    cfg.baseUrl = this.baseUrl.trim();
    cfg.apiKey = this.apiKey.trim();
    // 空行会被丢弃; 当前模型若已被删掉就落到第一个模型, 保证 model 始终属于 models
    let names: string[] = ApiConfig.normalizeModels(this.models, '');
    let current: string = this.model.trim();
    if (names.indexOf(current) === -1) {
      current = names.length > 0 ? names[0] : '';
    }
    cfg.model = current;
    cfg.models = names;
    cfg.extraBody = this.extraBody.trim();
    let temperature: number = parseFloat(this.temperature);
    cfg.temperature = this.temperature.trim() !== '' && !isNaN(temperature) ? temperature : null;
    let topP: number = parseFloat(this.topP);
    cfg.topP = this.topP.trim() !== '' && !isNaN(topP) ? topP : null;
    let maxTokens: number = parseInt(this.maxTokens, 10);
    cfg.maxTokens = this.maxTokens.trim() !== '' && !isNaN(maxTokens) ? maxTokens : null;
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
    cfg.preparseUserSet = this.mmPreparseUserSet;
    return cfg;
  }

  private buildSearchConfig(): SearchEngineSettings {
    this.applySearchFieldsToDraft();
    this.searchDraft.engine = this.searchEngine;
    // 条数是数字输入框: 空/非法/越界一律夹到 1~20
    let n: number = parseInt(this.searchMaxResults, 10);
    if (isNaN(n)) {
      n = 8;
    }
    if (n < 1) {
      n = 1;
    }
    if (n > 20) {
      n = 20;
    }
    this.searchDraft.maxResults = n;
    return this.searchDraft;
  }
}
