# Windows Server 2012 R2から2022へのドメインコントローラー移行

## 概要

本記事では、Windows Server 2012 R2で稼働しているドメインコントローラーを、Windows Server 2022へ移行する手順を検証する。

既存ドメインへWindows Server 2022のドメインコントローラーを追加し、レプリケーションの確認、FSMOとDNS設定の移行、旧DCの降格を行う。最後に、ドメインおよびフォレストの機能レベルをWindows Server 2016へ引き上げ、移行後の動作を確認する。

## 目次
- [検証構成と前提](#検証構成と前提)
- [Step 1. DC2022の追加](#step-1-dc2022の追加)
- [Step 2. 新旧DCの複製確認](#step-2-新旧dcの複製確認)
- [Step 3. FSMOの転送](#step-3-fsmoの転送)
- [Step 4. DNS設定の移行と参照先の切り替え](#step-4-dns設定の移行と参照先の切り替え)
- [Step 5. 旧DCの降格](#step-5-旧dcの降格)
- [Step 6. 機能レベルの引き上げ](#step-6-機能レベルの引き上げ)
- [Step 7. Windows 11が利用するDCの確認](#step-7-windows-11が利用するdcの確認)
- [まとめ](#まとめ)

## 検証構成と前提

移行前は、DC2012R2-01とDC2012R2-02の2台でドメインコントローラーを構成しており、両DC間のレプリケーションは正常に動作している。
Windows 11クライアントはドメインに参加し、優先DNSにDC2012R2-01、代替DNSにDC2012R2-02を設定している。
また、両DCには外部DNSを転送元とするセカンダリゾーンと、外部DNSを転送先とする条件付きフォワーダーを設定している。条件付きフォワーダーは、ADに保存する設定とDC2012R2-01のみに保存する設定を用意し、DC2022への引き継ぎ結果を比較する。

![before_migration.png](./images/before_migration.png)

また条件付きフォワーダーの詳細は以下となる

| 条件付きフォワーダー名 | 設定の保存場所・反映範囲 |
| --- | --- |
| `forward.example.test` | ADに保存し、ドメイン内のDNSサーバーへ複製 |
| `forward-local.example.test` | DC2012R2-01のみに保存 |

## Step 1. DC2022の追加

DC2022をドメインに参加させ、AD DSをインストールした後、追加のドメインコントローラーへ昇格する。
作業前のDC2022はドメインに参加しておらず、優先DNSにDC2012R2-01、代替DNSにDC2012R2-02を設定している。

![image.png](./images/image1.png)

### AD DSのインストール

ではドメインサービスのインストールを行う。作業前にローカルの管理者であることを確認する。  
サーバマネージャーを開き、役割と機能の追加を選択

![image.png](./images/image2.png)

<br>

「役割と機能の追加ウィザード」が開き、「次へ」を選択。

![image.png](./images/image3.png)

<br>
「役割ベースまたは機能ベースのインストール」を選択。

![image.png](./images/image4.png)

<br>
「サーバー プールからサーバーを選択」を選択。今回追加するDC2022を選択し「次へ」を選択。

![image.png](./images/image5.png)

<br>
「Active Directory ドメイン サービス」にチェックを入れる。

![image.png](./images/image6.png)

<br>
「役割と機能の追加ウィザード」が表示されるので「機能の追加」を選択。

![image.png](./images/image7.png)

<br>
「Active Directory ドメイン サービス」にチェックがついたことを確認し「次へ」を選択。  

この時点では、「DNSサーバー」にはチェックを入れない。DNSサーバー役割は、後続のドメインコントローラー昇格ウィザードで「DNSサーバー」を選択することにより、昇格処理の中でインストールされるため。

![image.png](./images/image8.png)

<br>
特に何も選択せず「次へ」を選択。

![image.png](./images/image9.png)

<br>
「次へ」を選択。

![image.png](./images/image10.png)

<br>
内容を確認し「インストール」を選択。

![image.png](./images/image11.png)

<br>
インストールが終わるまで待つ（約10分程度）。終わったら「閉じる」を選択。

![image.png](./images/image12.png)

<br>
Powershellで以下のコマンドを実行し、「Active Directory ドメイン サービス」がインストールされていることを確認する。

```powershell
 Get-WindowsFeature | Where-Object InstallState -eq 'Installed'
```

### ドメインコントローラーへの昇格

「サーバー マネージャー」の通知アイコンを選択し、「このサーバーをドメインコントローラーに昇格する」を選択する

![image.png](./images/image13.png)

<br>
「既存のドメインにドメイン コントローラーを追加する」を選択。ここで次に青枠の「選択」をクリックしたくなるが、先に「この操作を実行するには資格情報を指定してください」の「変更」を選択。先にドメイン管理者の資格情報が入力されてないと、青枠の「選択」欄でエラーが出るため。

![image.png](./images/image14.png)

<br>
資格情報を入力して「OK」を選択

![image.png](./images/image15.png)

<br>
「この操作のドメイン情報を指定してください」を選択して、ドメインを選択し「OK」を選択。

![image.png](./images/image16.png)

<br>
「次へ」を選択

![image.png](./images/image17.png)

<br>
「ドメイン ネーム システム (DNS) サーバー」、「グローバル カタログ (GC)」のチェックをオンにする（このタイミングでDNSの役割がインストールされる）
「サイト名」は、リストから対象のサイトを選択。ディレクトリサービス復元モードのパスワードを入力し、「次へ」を選択。

![image.png](./images/image18.png)

<br>
何もチェックを付けずに「次へ」を選択

![image.png](./images/image19.png)

<br>
「レプリケート元」に既存のドメコンを選択し「次へ」を選択。

![image.png](./images/image20.png)

<br>
「次へ」を選択。

![image.png](./images/image21.png)

<br>
「次へ」を選択。

![image.png](./images/image22.png)

<br>
内容を確認して「次へ」を選択

![image.png](./images/image23.png)

<br>
前提条件のチェックが実行される「すべての前提条件のチェックに合格しました。[インストール] をクリックしてインストールを開始してください。」と表示されたら、「インストール」を選択

![image.png](./images/image24.png)

<br>
ドメインサービスのインストールが完了するとサーバーは自動的に再起動される。

## Step 2. 新旧DCの複製確認

新旧DCが同期していることを確認する。  
DC2022で以下を実行し3台のDCが表示される。失敗数が0であることを確認する。

```powershell
repadmin /replsummary
```

```
実行結果：
レプリケーションの要約開始時刻: 2026-09-13 01:40:02

レプリケーションの要約のためのデータ収集を開始します。
これにはしばらく時間がかかる場合があります:
  ......

ソース DSA          最大デルタ    失敗/合計 %%   エラー
 DC2012R2-01               21m:01s    0 /  10    0
 DC2012R2-02               21m:01s    0 /  10    0
 DC2022                    11m:12s    0 /  10    0

宛先 DSA     最大デルタ    失敗/合計 %%   エラー
 DC2012R2-01               21m:01s    0 /  10    0
 DC2012R2-02               21m:01s    0 /  10    0
 DC2022                    16m:08s    0 /  10    0
```

<br>
各ディレクトリパーティションの最終試行が成功していることを確認する

```powershell
repadmin /showrepl DC2022
```

```
実行結果：
MAIN-SITE\DC2022
DSA オプション: IS_GC
サイト オプション: (none)
DSA オブジェクト GUID: 74c71384-c703-43f9-8d2b-bfaedc37dde2
DSA 起動 ID: 3c7e568a-cfae-4755-87fa-a897e13aeab2

==== 入力方向の近隣サーバー======================================

DC=frslab,DC=example,DC=test
    MAIN-SITE\DC2012R2-02 (RPC 経由)
        DSA オブジェクト GUID: 52f07824-c34e-464a-a24a-27450d6144d8
       2026-09-13 01:29:40 の最後の試行は成功しました。
    MAIN-SITE\DC2012R2-01 (RPC 経由)
        DSA オブジェクト GUID: c558f961-692a-49f1-827f-bf4f9634bc5c
       2026-09-13 01:43:07 の最後の試行は成功しました。

CN=Configuration,DC=frslab,DC=example,DC=test
    MAIN-SITE\DC2012R2-02 (RPC 経由)
        DSA オブジェクト GUID: 52f07824-c34e-464a-a24a-27450d6144d8
       2026-09-13 01:29:22 の最後の試行は成功しました。
    MAIN-SITE\DC2012R2-01 (RPC 経由)
        DSA オブジェクト GUID: c558f961-692a-49f1-827f-bf4f9634bc5c
       2026-09-13 01:29:37 の最後の試行は成功しました。

CN=Schema,CN=Configuration,DC=frslab,DC=example,DC=test
    MAIN-SITE\DC2012R2-01 (RPC 経由)
        DSA オブジェクト GUID: c558f961-692a-49f1-827f-bf4f9634bc5c
       2026-09-13 01:23:54 の最後の試行は成功しました。
    MAIN-SITE\DC2012R2-02 (RPC 経由)
        DSA オブジェクト GUID: 52f07824-c34e-464a-a24a-27450d6144d8
       2026-09-13 01:28:25 の最後の試行は成功しました。

DC=ForestDnsZones,DC=frslab,DC=example,DC=test
    MAIN-SITE\DC2012R2-01 (RPC 経由)
        DSA オブジェクト GUID: c558f961-692a-49f1-827f-bf4f9634bc5c
       2026-09-13 01:29:25 の最後の試行は成功しました。
    MAIN-SITE\DC2012R2-02 (RPC 経由)
        DSA オブジェクト GUID: 52f07824-c34e-464a-a24a-27450d6144d8
       2026-09-13 01:29:34 の最後の試行は成功しました。

DC=DomainDnsZones,DC=frslab,DC=example,DC=test
    MAIN-SITE\DC2012R2-02 (RPC 経由)
        DSA オブジェクト GUID: 52f07824-c34e-464a-a24a-27450d6144d8
       2026-09-13 01:44:48 の最後の試行は成功しました。
    MAIN-SITE\DC2012R2-01 (RPC 経由)
        DSA オブジェクト GUID: c558f961-692a-49f1-827f-bf4f9634bc5c
       2026-09-13 01:44:54 の最後の試行は成功しました。

```

<br>
SYSVOLとNETLOGONが表示されることを確認する

```powershell
net share
```

```
実行結果：

共有名       リソース                            注釈

-------------------------------------------------------------------------------
C$           C:\                             Default share
IPC$                                         Remote IPC
ADMIN$       C:\Windows                      Remote Admin
NETLOGON     C:\Windows\SYSVOL\sysvol\frslab.example.test\SCRIPTS
                                             Logon server share
SYSVOL       C:\Windows\SYSVOL\sysvol        Logon server share
コマンドは正常に終了しました。

```

<br>
以下のコマンドを実行し、ReplicatedFolderNameがSYSVOL Share、Stateが4（正常）、LastErrorCodeが0であることを確認する

```powershell
Get-CimInstance -Namespace "root\microsoftdfs" -ClassName "DfsrReplicatedFolderInfo"
```

```
実行結果：
CurrentConflictSizeInMb  : 0
CurrentStageSizeInMb     : 0
LastConflictCleanupTime  : 2026/09/13 1:24:07
LastErrorCode            : 0
LastErrorMessageId       : 0
LastTombstoneCleanupTime : 2026/09/13 1:24:07
MemberGuid               : 1A41E59E-770E-4A2F-8F26-659DA794BF75
MemberName               : DC2022
ReplicatedFolderGuid     : 1D89E473-3ABF-40A2-9DA7-1A1CF3CF82BF
ReplicatedFolderName     : SYSVOL Share
ReplicationGroupGuid     : 5C5AE50A-125B-47E3-A10B-994A221050D8
ReplicationGroupName     : Domain System Volume
State                    : 4
PSComputerName           :
```

<br>
DC2022でテストファイルを作成し、それがDC2012R2-01／02へ複製されることを確認する。  
これらのテストファイルはDC2012R2-01／02ではC:\Windows\SYSVOL_DFSR\domain\scriptsに作成されるので注意

```powershell
New-Item C:\Windows\SYSVOL\domain\scripts\dfsr-test.txt -ItemType File
```

![image.png](./images/image25.png)

<br>
イベントビューアーを開き、「アプリケーションとサービス ログ」ー「DFS Replication」イベントログに、DFSRでの初期同期完了を示すID:4604のイベントが記録されていることを確認

![image.png](./images/image26.png)

## Step 3. FSMOの転送

次にFSMO転送を行う。  
管理者としてPowerShellを開き、現在のFSMO役割の保持先を確認する。全5役割をDC2012R2-01が保持していることを確認。

```powershell
netdom query fsmo
```

```
実行結果：
スキーマ マスター                DC2012R2-01.frslab.example.test
ドメイン名前付けマスター        DC2012R2-01.frslab.example.test
PDC                         DC2012R2-01.frslab.example.test
RID プール マネージャー        DC2012R2-01.frslab.example.test
インフラストラクチャ マスター    DC2012R2-01.frslab.example.test
コマンドは正しく完了しました。
```

<br>
転送先のDC2022がドメインコントローラーとして登録されていることを確認する。実行結果にDC2022が表示され、既存のDCと同じMAIN-SITEに登録されていることを確認。

```powershell
Get-ADDomainController -Filter * | Select-Object Name, HostName, Site
```

```
実行結果：
Name        HostName                        Site
----        --------                        ----
DC2022      DC2022.frslab.example.test      MAIN-SITE
DC2012R2-02 DC2012R2-02.frslab.example.test MAIN-SITE
DC2012R2-01 DC2012R2-01.frslab.example.test MAIN-SITE
```

<br>
FSMOの全5役割をDC2022へ転送する。各操作マスターを移動するか確認を求められたら、Yを入力して処理を続行する。

```powershell
Move-ADDirectoryServerOperationMasterRole -Identity "DC2022" -OperationMasterRole PDCEmulator,RIDMaster,InfrastructureMaster,SchemaMaster,DomainNamingMaster
```

```powershell
実行結果：
操作マスターの役割の移動
役割 'PDCEmulator' をサーバー 'DC2022.frslab.example.test' に移動しますか?
[Y] はい(Y)  [A] すべて続行(A)  [N] いいえ(N)  [L] すべて無視(L)  [S] 中断(S)  [?] ヘルプ (既定値は "Y"): y

操作マスターの役割の移動
役割 'RIDMaster' をサーバー 'DC2022.frslab.example.test' に移動しますか?
[Y] はい(Y)  [A] すべて続行(A)  [N] いいえ(N)  [L] すべて無視(L)  [S] 中断(S)  [?] ヘルプ (既定値は "Y"): y

操作マスターの役割の移動
役割 'InfrastructureMaster' をサーバー 'DC2022.frslab.example.test' に移動しますか?
[Y] はい(Y)  [A] すべて続行(A)  [N] いいえ(N)  [L] すべて無視(L)  [S] 中断(S)  [?] ヘルプ (既定値は "Y"): y

操作マスターの役割の移動
役割 'SchemaMaster' をサーバー 'DC2022.frslab.example.test' に移動しますか?
[Y] はい(Y)  [A] すべて続行(A)  [N] いいえ(N)  [L] すべて無視(L)  [S] 中断(S)  [?] ヘルプ (既定値は "Y"): y

操作マスターの役割の移動
役割 'DomainNamingMaster' をサーバー 'DC2022.frslab.example.test' に移動しますか?
[Y] はい(Y)  [A] すべて続行(A)  [N] いいえ(N)  [L] すべて無視(L)  [S] 中断(S)  [?] ヘルプ (既定値は "Y"): y

```

<br>
再度結果を確認し、5つの役割がDC2022に代わっていることを確認する。

```powershell
netdom query fsmo
```

```powershell
実行結果：
スキーマ マスター                DC2022.frslab.example.test
ドメイン名前付けマスター        DC2022.frslab.example.test
PDC                         DC2022.frslab.example.test
RID プール マネージャー        DC2022.frslab.example.test
インフラストラクチャ マスター    DC2022.frslab.example.test
コマンドは正しく完了しました。
```

<br>
FSMO転送後もADレプリケーションが正常に動作していることを確認する。先ほどと同じく以下のコマンドを実行し、失敗数が0であり、各ディレクトリパーティションの最終複製試行が成功していることを確認する。

```powershell
repadmin /replsummary
repadmin /showrepl DC2022
```

<br>
続いて、新しくPDCエミュレーターとなったDC2022の時刻同期状態を確認する。

```powershell
w32tm /query /source
w32tm /query /status
```

時刻同期元に廃止予定のDC2012R2-01またはDC2012R2-02が表示されていないことを確認する。

ちなみにDC2022ではFSMO転送直後はDC2012R2-01が時刻同期元として表示されたが、一定時間経過後に再確認するとLocal CMOS Clockへ切り替わっていた。DC2022がPDCエミュレーターとして認識され、時刻同期元が再評価されたため、設定変更は実施しなかった。

また、Microsoftは、通常のドメイン参加コンピューターはNT5DSでドメイン階層に従い、最上位のPDCエミュレーターは外部時刻源と同期する構成を示しているので、必要に応じて時刻同期の設定を行うこと。  
[https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings?utm_source=chatgpt.com&tabs=config](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings?utm_source=chatgpt.com&tabs=config)

## Step 4. DNS設定の移行と参照先の切り替え

旧DCを降格する前に、DC2022へ必要なDNS設定を移行し、ドメイン内のDNS問い合わせが旧DCに依存しない状態へ切り替える。

DNS設定には、ADレプリケーションによってDC2022へ自動的に複製されるものと、サーバーごとに手動設定が必要なものがある。最初にDC2022のDNS設定を確認・補完し、名前解決が正常に行えることを確認してから、ネームサーバーおよびDNSクライアントの参照先を切り替える。

### DNSサーバー設定の移行

DC2012R2-01／02で「サーバーマネージャー」－「ツール」－「DNS」を開き、各DNS設定の種類と保存方法を確認する。今回の構成では、前方参照ゾーンのsecondary.example.testと、ADに保存されていない条件付きフォワーダーforward-local.example.testが該当する。これらはDC2022へ自動的に複製されないため、DC2022へ手動で設定する必要がある。

![image.png](./images/image27.png)

![image.png](./images/image28.png)

<br>
まず、DC2022でsecondary.example.testのセカンダリを追加する。「前方参照ゾーン」で右クリックし、「新しいゾーン」を選択。

![image.png](./images/image29.png)

<br>
「次へ」を選択

![image.png](./images/image30.png)

<br>
セカンダリゾーンを選択し、「次へ」を選択

![image.png](./images/image31.png)

<br>
ゾーン名で今回追加する「secondary.example.test」を入力して「次へ」を選択。

![image.png](./images/image32.png)

<br>
IPアドレスで参照元のDNSサーバのIPを入力して「次へ」を選択

![image.png](./images/image33.png)

<br>
内容確認して「完了」とする

![image.png](./images/image34.png)

<br>
新しく作成された「secondary.example.test」を参照する。画像のように「DNSサーバに読み込まれていないゾーン」と出ていたら、転送許可、マスターサーバーの指定、通信状態を確認する。

![image.png](./images/image35.png)

<br>
※DNSサーバ側で「secondary.example.test」がDC2022（192.168.57.53）を読み取れるようにゾーン転送を許可する場合。

![image.png](./images/image36.png)

<br>
再度DC2022の設定に戻り、「操作」－「マスターから転送」を選択。

![image.png](./images/image37.png)

<br>
再度画面を更新するとDC2022で「secondary.example.test」の値が表示される。

![image.png](./images/image38.png)

<br>
条件付きフォワーダーの設定も同様。「条件付きフォワーダーを右クリックして、「新規条件付きフォワーダー」を選択、下記のようにドメインやマスターサーバのアドレスを入力。

![image.png](./images/image39.png)

<br>
以下のようにDC2022もDC2012R2-01と同じ構成となった。

![image.png](./images/image40.png)

<br>
DNS設定が完了したら、WIN11からDC2022を問い合わせ先DNSサーバーとして指定し、secondary.example.testおよびforward-local.example.testの名前解決を確認する。

各ゾーンに登録されている実在するAレコードを指定し、以下のコマンドを実行する。

```powershell
Resolve-DnsName <実在するホスト名>.secondary.example.test -Server 192.168.57.53 -DnsOnly
Resolve-DnsName <実在するホスト名>.forward-local.example.test -Server 192.168.57.53 -DnsOnly
```

<br>
それぞれの実行結果に、対象レコードの正しいIPアドレスが表示されることを確認する。  
筆者の環境では、以下のように名前解決できることを確認した。

```
PS C:\Users\user01> Resolve-DnsName second_test.secondary.example.test -Server 192.168.57.53 -DnsOnly

Name                                           Type   TTL   Section    IPAddress
----                                           ----   ---   -------    ---------
second_test.secondary.example.test             A      3600  Answer     192.168.57.40

PS C:\Users\user01> Resolve-DnsName forward-local.forward-local.example.test -Server 192.168.57.53 -DnsOnly

Name                                           Type   TTL   Section    IPAddress
----                                           ----   ---   -------    ---------
forward-local.forward-local.example.test       A      3599  Answer     192.168.57.42

```

### _msdcsの委任先変更

_msdcs.frslab.example.testゾーンのネームサーバーへDC2022を追加する。DC2022が登録されたことを確認した後、廃止予定のDC2012R2-01／02をネームサーバー一覧から削除する。  
「DNS マネージャー」ー「前方参照ゾーン」ー「<ドメイン名>」の「_msdcs」を開く。
「_msdcs」を右クリックし、「プロパティ」を選択

![image.png](./images/image41.png)

<br>
ネームサーバタグを選択。すでにDC2022が登録されているが、もし登録しない場合は「追加」で新しく選択。

ここではIPアドレスが不明になっているのでそれを修正する。DC2022を選び「編集」を選択

![image.png](./images/image42.png)

<br>
「解決」を選択して名前解決できることを確認し「OK」を選択。ここで「::1」が入力された場合、これは::1はIPv6のループバックアドレスなので「削除」を選択し、IPv4アドレスのみにする。

![image.png](./images/image43.png)

<br>
DC2022のIPアドレスが表示されるようになったら、不要なdc2012を削除する。

![image.png](./images/image44.png)

<br>
不要なDCを削除してOK

![image.png](./images/image45.png)

### DNSクライアントの参照先変更

DC2022およびドメイン参加端末のDNSクライアント設定を確認し、旧DCを参照している設定をDC2022へ変更する。

DC2022ではncpa.cplを実行してネットワーク接続を開き、優先DNSサーバーをDC2022自身のIPアドレスへ変更する。代替DNSサーバーには、ADドメインの名前解決が可能な別のDNSサーバーがある場合のみ、そのIPアドレスを指定する（今回は空欄）

> ⚠️ ドメイン参加端末のDNS参照先も、旧DCの降格前に変更する
> 
> 
> 旧DCを参照したまま降格すると、端末が利用可能なDCを検出できず、ドメインへのログオンやグループポリシーの更新に失敗する可能性がある。
> 
> 本検証ではWindows 11の変更を失念したため、旧DC降格後もDNS参照先にDC2012R2-01／02が残り、`nltest`でDCを検出できず、`gpupdate`にも失敗した。DNS参照先をDC2022へ変更することで解消した。
> 

![image.png](./images/image46.png)

## Step 5. 旧DCの降格

### 旧DCの降格

次に既存DCの降格を行う。  
「サーバー マネージャー」ー「管理」－「役割と機能の削除」を選択。

![image.png](./images/image47.png)

<br>
「次へ」を選択

![image.png](./images/image48.png)

<br>
DC2012R2-01を選択し「次へ」を選択

![image.png](./images/image49.png)

<br>
削除する機能のチェックボックスをオフにする。「Active Directory ドメイン サービス」を選択

![image.png](./images/image50.png)

<br>
「機能の削除」を選択

![image.png](./images/image51.png)

<br>
「検証結果」ー「このドメイン コントローラーを降格する」を選択

![image.png](./images/image52.png)

<br>
「次へ」を選択

![image.png](./images/image53.png)

<br>
「削除の続行」にチェックを入れ「次へ」を選択

![image.png](./images/image54.png)

<br>
降格した後のAdministratorのパスワードを入力

![image.png](./images/image55.png)

<br>
内容を確認して「降格」を選択。自動的に再起動が走るので注意！

![image.png](./images/image56.png)

<br>
DC2012R2-01の降格後、DC2022で以下のコマンドを実行し、ドメインコントローラーの一覧を確認する。

```powershell
Get-ADDomainController -Filter * | Select Name,Site
```

```powershell
実行結果：
Name        Site
----        ----
DC2022      MAIN-SITE
DC2012R2-02 MAIN-SITE
```

実行結果にDC2022と、まだ降格していないDC2012R2-02だけが表示され、DC2012R2-01が表示されないことを確認する。確認後、DC2012R2-02についても同様に降格作業を行う。

### 降格後の確認

DC2022で以下のコマンドを実行し、ドメインコントローラーとしてDC2022だけが登録されていることを確認する。

```powershell
Get-ADDomainController -Filter * | Select Name,Site

実行結果：
Name        Site
----        ----
DC2022      MAIN-SITE
```

<br>
「Active Directory サイトとサービス」を開き、次の場所を確認する。

![image.png](./images/image57.png)

降格したDC2012R2-01／02のServerオブジェクトが残っている場合は、配下にNTDS Settingsなどの子オブジェクトがないことを確認してから削除する。
削除後、Servers配下にDC2022だけが残っていることを確認する。

<br>
DC2022で「Active Directory ユーザーとコンピューター」を開き、Domain ControllersにDC2022以外のサーバが残っていないことを確認する

![image.png](./images/image58.png)

<br>
各項目にpassed testが表示されることを確認する

```powershell
dcdiag /s:DC2022 /test:Advertising /test:Services /test:SysVolCheck /test:NetLogons /test:DNS
```

```powershell
実行結果：
ディレクトリ サーバー診断

初期セットアップを実行しています:
   * AD フォレストが識別されました。
   初期情報の収集が完了しました。

必須の初期テストを実行しています

   サーバーをテストしています: MAIN-SITE\DC2022
      テストを開始しています: Connectivity
         ......................... DC2022 はテスト Connectivity に合格しました

プライマリ テストを実行しています

   サーバーをテストしています: MAIN-SITE\DC2022
      テストを開始しています: Advertising
         ......................... DC2022 はテスト Advertising に合格しました
      テストを開始しています: SysVolCheck
         ......................... DC2022 はテスト SysVolCheck に合格しました
      テストを開始しています: NetLogons
         ......................... DC2022 はテスト NetLogons に合格しました
      テストを開始しています: Services
         ......................... DC2022 はテスト Services に合格しました

      テストを開始しています: DNS

         DNS テストは実行中であり、ハングしていません。しばらくお待ちください...
         ......................... DC2022 はテスト DNS に合格しました

   パーティション テストを実行しています: DomainDnsZones

   パーティション テストを実行しています: ForestDnsZones

   パーティション テストを実行しています: Schema

   パーティション テストを実行しています: Configuration

   パーティション テストを実行しています: frslab

   エンタープライズ テストを実行しています: frslab.example.test
      テストを開始しています: DNS
         ......................... frslab.example.test はテスト DNS に合格しました
```

## Step 6. 機能レベルの引き上げ

ドメイン機能レベルを昇格させる  
「サーバー マネージャー」ー「ツール」ー「Active Directory ドメインと信頼関係」でドメインを右クリックし、「ドメインの機能レベルの昇格」を選択

![image.png](./images/image59.png)

<br>
「利用可能なドメインの機能レベルを選択してください」で、「Windows Server 2016」を選択。

![image.png](./images/image60.png)

<br>
「OK」を選択

![image.png](./images/image61.png)

<br>
「OK」を選択

![image.png](./images/image62.png)

<br>
「Active Directory ドメインと信頼関係 」で右クリックし、「フォレストの機能レベルの昇格」を選択

![image.png](./images/image63.png)

<br>
「利用可能なフォレストの機能レベルを選択してください」で、「Windows Server 2016」を選択

![image.png](./images/image64.png)

<br>
「OK」を選択

![image.png](./images/image65.png)

<br>
「OK」を選択

![image.png](./images/image66.png)

以上で作業は完了。

## Step 7. Windows 11が利用するDCの確認

Windows 11でログオンに使用したDCと検出できるDCを確認する。旧DCの降格後、Windows 11のDNS参照先をDC2022へ変更し、サインアウトまたは再起動してから再度確認する。

※またここでwin11のDNSがDC2022を向いていないとログオン先DCは変わらないので注意


| Win11確認タイミング | ログオン先DC（`$env:LOGONSERVER`） | 認識できるDC<br>（`nltest /dclist:frslab.example.test`） |
| --- | --- | --- |
| DC2022昇格前 | \\DC2012R2-01 | DC2012R2-01、DC2012R2-02 |
| DC2022昇格後 | \\DC2012R2-01 | DC2012R2-01、DC2012R2-02、DC2022<br>※[PDC]のフラグはDC2012R2-01についている |
| FSMO転送後 | \\DC2012R2-01 | DC2012R2-01、DC2012R2-02、DC2022<br>※[PDC]のフラグはDC2022についている |
| 旧DC降格・再ログオン後 | \\DC2022 | DC2022 |

## まとめ

Windows Server 2012 R2のドメインへWindows Server 2022のDCを追加し、レプリケーションの確認、FSMOとDNS設定の移行、旧DCの降格を実施した。

ADに保存されたDNS設定は自動的に複製されたが、セカンダリゾーンやADに保存されていない条件付きフォワーダーは手動で移行する必要があった。また、旧DCの降格前にDCとドメイン参加端末のDNS参照先を切り替える必要があることを確認した。

最後に、ドメインおよびフォレストの機能レベルをWindows Server 2016へ引き上げ、DC2022とDNSが正常に動作することを確認した。
