$ErrorActionPreference = 'Stop'
$path = (Resolve-Path 'entry/src/main/ets/viewmodel/ChatViewModel.ets').Path
$text = [System.IO.File]::ReadAllText($path)
$driverStartMarker = 'private async executeWorkLoopDriver(conv: Conversation): Promise<void> {'
$driverStart = $text.IndexOf($driverStartMarker)
$nextMethodMarker = '  private async runStepWithOverflowRetry('
$nextMethod = $text.IndexOf($nextMethodMarker, $driverStart)
if ($driverStart -lt 0 -or $nextMethod -lt 0) { throw 'driver markers not found' }
$driverMethod = $text.Substring($driverStart, $nextMethod - $driverStart)
if ($driverMethod.Contains('runDriverStep')) { throw 'runDriverStep already exists' }
$arrowStartMarker = 'let res = await WorkLoopDriverBridge.runWithStep(async (i: number): Promise<WorkLoopTurnInfo> => {'
$arrowStart = $driverMethod.IndexOf($arrowStartMarker)
$arrowEndMarker = "      }, Constants.WORK_MAX_STEPS, (s: number, action: string): void => {"
$arrowEnd = $driverMethod.IndexOf($arrowEndMarker, $arrowStart)
if ($arrowStart -lt 0 -or $arrowEnd -lt 0) { throw 'arrow markers not found' }
$closure = $driverMethod.Substring($arrowStart + $arrowStartMarker.Length, $arrowEnd - ($arrowStart + $arrowStartMarker.Length))
$closure = $closure.TrimStart("`r", "`n", " ")
$closure = $closure.Replace('turnEndStatus', 'state.turnEndStatus')
$closure = $closure.Replace('finalAnswerText', 'state.finalAnswerText')
$closure = $closure.Replace('traceSeq', 'state.traceSeq')
$closure = $closure.Replace('let step: number = i;', 'let step: number = stepIndex;')
$method = "  private async runDriverStep(conv: Conversation, messages: LoopMessage[], metrics: LoopMetrics,`n" +
  "    turnToolEvents: Record<string, Object>[], state: WorkLoopStepState, stepIndex: number): Promise<WorkLoopTurnInfo> {`n" +
  $closure + "`n  }"
$oldSegment = $driverMethod.Substring($arrowStart, $arrowEnd - $arrowStart)
$newSegment = "let state: WorkLoopStepState = new WorkLoopStepState();`n" +
  "      let res = await WorkLoopDriverBridge.runWithStep(async (i: number): Promise<WorkLoopTurnInfo> => {`n" +
  "        return await this.runDriverStep(conv, messages, metrics, turnToolEvents, state, i);"
$newDriverMethod = $driverMethod.Replace($oldSegment, $newSegment)
$afterBlockOld = "      if (res.maxStepsReached) {`n        step = Constants.WORK_MAX_STEPS;`n      }`n      if (this.context !== null) {"
$afterBlockNew = "      if (res.maxStepsReached) {`n        step = Constants.WORK_MAX_STEPS;`n      }`n      turnEndStatus = state.turnEndStatus;`n      finalAnswerText = state.finalAnswerText;`n      if (this.context !== null) {"
if (-not $newDriverMethod.Contains($afterBlockOld)) { throw 'after block not found' }
$newDriverMethod = $newDriverMethod.Replace($afterBlockOld, $afterBlockNew)
$newText = $text.Substring(0, $driverStart) + $newDriverMethod + "`n`n" + $method + $text.Substring($nextMethod)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $newText, $utf8)
$hasCall = $newText.Contains('this.runDriverStep(conv, messages, metrics, turnToolEvents, state, i)')
$hasMethod = $newText.Contains('private async runDriverStep(')
$newLen = $newText.Length
Write-Output ("REFACTOR_INSERTED len=" + $newLen)
Write-Output ("HAS_CALL=" + $hasCall)
Write-Output ("HAS_METHOD=" + $hasMethod)
