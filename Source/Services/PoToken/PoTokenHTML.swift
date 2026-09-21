//
//  PoTokenHTML.swift
//  ViviMusic
//
//  WebView に読み込ませる BotGuard 実行用の HTML/JS。
//  本家 VIVI Music の `assets/po_token.html` の移植 (元は NewPipe / BgUtils 系)。
//
//  ここに外部リソースへの参照は無い。
//  BotGuard のインタプリタ本体は、ネイティブ側が取ってきたチャレンジの中に
//  JavaScript のソースとして入っており、`new Function(...)` で読み込まれる。
//
//  ネイティブとのやり取りは `window.webkit.messageHandlers.vivi.postMessage()` で行う。
//

enum PoTokenHTML {

    static let page = """
    <!DOCTYPE html>
    <html lang="en"><head><title></title><script>
    // ネイティブへ結果を返す共通口
    function send(payload) {
      try {
        window.webkit.messageHandlers.vivi.postMessage(payload);
      } catch (e) { /* 送れないときは諦める */ }
    }

    var bgVmFunctions = null;
    var bgVm = null;
    var bgProgram = null;
    var poTokenMinter = null;   // ミンターは初期化時に一度だけ作り、以後使い回す
    var webPoSignalOutput = null;
    var integrityToken = null;

    // BotGuard の VM を読み込み、関数群が揃うまで待つ
    function loadBotGuard(challengeData) {
      bgVm = window[challengeData.globalName];
      bgProgram = challengeData.program;
      bgVmFunctions = null;

      if (!bgVm) throw new Error('VM がグローバルに見つかりません');
      if (!bgVm.a) throw new Error('プログラムを読み込めません');

      var vmFunctionsCallback = function (asyncSnapshotFunction, shutdownFunction,
                                          passEventFunction, checkCameraFunction) {
        bgVmFunctions = {
          asyncSnapshotFunction: asyncSnapshotFunction,
          shutdownFunction: shutdownFunction,
          passEventFunction: passEventFunction,
          checkCameraFunction: checkCameraFunction
        };
      };

      try {
        bgVm.a(bgProgram, vmFunctionsCallback, true, undefined,
               function () { /* no-op */ }, [ [], [] ]);
      } catch (e) {
        throw new Error('プログラムの実行に失敗: ' + e.message);
      }

      // vmFunctions は非同期に埋まるので待つ
      return new Promise(function (resolve, reject) {
        var attempts = 0;
        var timer = setInterval(function () {
          if (bgVmFunctions && bgVmFunctions.asyncSnapshotFunction) {
            clearInterval(timer);
            resolve({ vmFunctions: bgVmFunctions, vm: bgVm, program: bgProgram });
          } else if (attempts >= 10000) {
            clearInterval(timer);
            reject(new Error('asyncSnapshotFunction を待ってタイムアウト'));
          }
          attempts++;
        }, 1);
      });
    }

    function snapshot(botguard, args) {
      return new Promise(function (resolve, reject) {
        if (!botguard.vmFunctions || !botguard.vmFunctions.asyncSnapshotFunction) {
          return reject(new Error('asyncSnapshotFunction がありません'));
        }
        try {
          botguard.vmFunctions.asyncSnapshotFunction(
            function (response) { resolve(response); },
            [ args.contentBinding, args.signedTimestamp,
              args.webPoSignalOutput, args.skipPrivacyBuffer ]
          );
        } catch (e) {
          reject(new Error('snapshot に失敗: ' + e.message));
        }
      });
    }

    // ネイティブから呼ばれる: チャレンジを受け取って BotGuard を走らせる
    function runBotGuard(challengeData) {
      var interpreterJavascript =
        challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
      if (!interpreterJavascript) {
        throw new Error('インタプリタの JavaScript がありません');
      }
      new Function(interpreterJavascript)();

      webPoSignalOutput = [];

      return loadBotGuard({
        globalName: challengeData.globalName,
        program: challengeData.program
      }).then(function (botguard) {
        return snapshot(botguard, { webPoSignalOutput: webPoSignalOutput });
      }).then(function (botguardResponse) {
        return { webPoSignalOutput: webPoSignalOutput, botguardResponse: botguardResponse };
      });
    }

    // integrityToken からミンターを作る。初期化時に一度だけ。
    async function createPoTokenMinter(signalOutput, token) {
      var getMinter = signalOutput[0];
      if (typeof getMinter !== 'function') {
        throw new Error('ミンター生成関数が見つかりません (' + typeof getMinter + ')');
      }
      var minterResult = getMinter(token);
      var mintCallback = (minterResult && typeof minterResult.then === 'function')
        ? await minterResult
        : minterResult;
      if (typeof mintCallback !== 'function') {
        throw new Error('ミンターが関数ではありません (' + typeof mintCallback + ')');
      }
      poTokenMinter = mintCallback;
    }

    // 識別子に紐づく poToken を作る
    async function obtainPoToken(identifier) {
      if (!poTokenMinter) throw new Error('ミンターが未初期化です');
      var mintResult = poTokenMinter(identifier);
      var result = (mintResult && typeof mintResult.then === 'function')
        ? await mintResult
        : mintResult;
      if (!result) throw new Error('生成結果が空です');
      if (!(result instanceof Uint8Array)) {
        throw new Error('生成結果が Uint8Array ではありません');
      }
      return result;
    }

    // ---- ネイティブから呼び出す入口 ----

    function viviRunBotGuard(challengeJson) {
      try {
        runBotGuard(JSON.parse(challengeJson)).then(function (result) {
          webPoSignalOutput = result.webPoSignalOutput;
          send({ type: 'botguard', value: result.botguardResponse });
        }, function (error) {
          send({ type: 'error', stage: 'botguard', value: String(error) });
        });
      } catch (error) {
        send({ type: 'error', stage: 'botguard', value: String(error) });
      }
    }

    function viviCreateMinter(tokenArray) {
      try {
        integrityToken = tokenArray;
        createPoTokenMinter(webPoSignalOutput, integrityToken).then(function () {
          send({ type: 'minter' });
        }).catch(function (error) {
          send({ type: 'error', stage: 'minter', value: String(error) });
        });
      } catch (error) {
        send({ type: 'error', stage: 'minter', value: String(error) });
      }
    }

    function viviObtainPoToken(identifier, u8Identifier) {
      try {
        obtainPoToken(u8Identifier).then(function (tokenU8) {
          send({ type: 'token', identifier: identifier, value: tokenU8.join(',') });
        }).catch(function (error) {
          send({ type: 'error', stage: 'token', identifier: identifier, value: String(error) });
        });
      } catch (error) {
        send({ type: 'error', stage: 'token', identifier: identifier, value: String(error) });
      }
    }

    // 読み込み完了をネイティブに知らせる
    send({ type: 'ready' });
    </script></head><body></body></html>
    """
}
