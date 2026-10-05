# Waydroid Headless Sway — Alpine LXC / Arch VM

Proxmox 환경에서 **Waydroid를 GUI 로그인 없이 Sway(headless) + WayVNC로 상시 구동**하기 위해 정리한 배포 저장소입니다.

현재 저장소는 두 가지 실행 환경을 지원합니다.

- **Alpine Linux LXC CT**: OpenRC 기반. LXC 안에서 Waydroid container와 사용자 세션을 함께 관리합니다.
- **Arch Linux VM**: systemd 기반. root가 수행할 준비 작업과 일반 사용자 Wayland 세션을 명확히 분리합니다.

두 환경 모두 최종적으로 다음 기능을 목표로 합니다.

- Sway headless compositor 위에서 Waydroid 실행
- WayVNC를 통한 원격 화면 접속
- `socat`을 통한 ADB TCP 포워딩
- Waydroid suspend 방지
- 정적 RRO(Runtime Resource Overlay) 자동 배치
- Android multi-user / Clone Profile 사용을 위한 설정
- 서비스 재시작 및 부팅 후 자동 기동

> 이 README는 현재 repository의 실제 스크립트를 기준으로 작성했습니다. 과거 작업 문서에 있던 Weston 구성, Alpine의 `/root/overlayapk` 또는 `${HOME}/overlayapk`, `hardware_manager.py` 직접 패치 등은 현재 구현과 다르므로 이 문서를 우선합니다.

---

## 1. Repository 구조

```text
way/
├── README.md
├── install.sh
│
├── alpine_lxc/
│   ├── install.sh
│   ├── alpine_pkgs
│   └── system/
│       ├── alpine-cgroup
│       ├── waydroid-sway
│       └── waydroid-sway-session
│
└── arch_vm/
    ├── install.sh
    ├── arch_packages
    ├── system/
    │   ├── waydroid-prepare
    │   ├── waydroid-prepare.service
    │   └── waydroid-container.service.d/
    │       └── override.conf
    └── user/
        ├── waydroid-sway
        └── waydroid-sway.service
```

설치 후 주요 파일은 다음 위치로 배치됩니다.

| 환경 | Repository 파일 | 설치 위치 |
|---|---|---|
| Alpine | `alpine_lxc/system/alpine-cgroup` | `/etc/init.d/alpine-cgroup` |
| Alpine | `alpine_lxc/system/waydroid-sway` | `/etc/init.d/waydroid-sway` |
| Alpine | `alpine_lxc/system/waydroid-sway-session` | `/usr/local/bin/waydroid-sway-session` |
| Arch | `arch_vm/system/waydroid-prepare` | `/usr/local/sbin/waydroid-prepare` |
| Arch | `arch_vm/system/waydroid-prepare.service` | `/etc/systemd/system/waydroid-prepare.service` |
| Arch | `arch_vm/system/waydroid-container.service.d/override.conf` | `/etc/systemd/system/waydroid-container.service.d/override.conf` |
| Arch | `arch_vm/user/waydroid-sway` | `~/.local/bin/waydroid-sway` |
| Arch | `arch_vm/user/waydroid-sway.service` | `~/.config/systemd/user/waydroid-sway.service` |

---

## 2. 전체 설계

### Alpine LXC

Alpine에서는 OpenRC 서비스 하나가 일반 사용자 세션에서 headless desktop과 Waydroid 실행 흐름을 관리합니다. Waydroid container 시작/정지처럼 root 권한이 필요한 작업만 `sudo`를 사용합니다.

```text
OpenRC
├── alpine-cgroup
│   └── cgroup v2 subtree 준비
│
└── waydroid-sway                  [일반 사용자로 실행]
    └── /usr/local/bin/waydroid-sway-session
        ├── Waydroid 설정/property 준비
        ├── RRO 배치
        ├── D-Bus session
        ├── PulseAudio
        ├── Sway headless
        ├── Waydroid container     [sudo/root]
        ├── Waydroid session
        ├── Waydroid full UI
        ├── ADB socat forwarding
        └── WayVNC
```

OpenRC의 `supervise-daemon`이 `waydroid-sway-session`을 감시하며 비정상 종료 시 재시작합니다.

### Arch VM

Arch는 system scope와 user scope를 분리합니다.

```text
systemd system
├── waydroid-prepare.service
│   └── /usr/local/sbin/waydroid-prepare
│       ├── waydroid.cfg 설정
│       ├── Android properties 설정
│       ├── RRO 배치
│       └── 변경 시 waydroid upgrade -o
│
└── waydroid-container.service
    └── Requires/After = waydroid-prepare.service

systemd --user
└── waydroid-sway.service
    └── ~/.local/bin/waydroid-sway
        ├── Sway headless
        ├── Waydroid session
        ├── Waydroid full UI
        ├── WayVNC
        └── ADB socat forwarding
```

즉 **Arch에서 `/var/lib/waydroid`와 container 준비는 root/system service**, 화면과 사용자 Waydroid session은 **일반 사용자 service**가 담당합니다.

---

## 3. 공통 Waydroid 설정

현재 스크립트가 적용하는 핵심 설정은 다음과 같습니다.

```ini
auto_adb = True
suspend_action = none

[properties]
persist.waydroid.suspend = false
ro.adb.secure = 0
fw.max_users = 5
fw.max_running_users = 5
fw.show_multiuserui = 1
```

목적은 다음과 같습니다.

- ADB 자동 활성화
- headless 환경에서 Waydroid suspend 방지
- ADB 인증 제약 완화
- Owner를 포함해 최대 5 user 운용 가능하도록 설정
- 여러 Android user를 동시에 running 상태로 유지
- Android multi-user UI 활성화

설정이 실제로 변경된 경우 overlay/config 반영을 위해 `waydroid upgrade -o`를 실행합니다.

---

# Alpine Linux LXC

## 4. Alpine 전제 조건

이 저장소는 **Waydroid가 실행 가능한 Alpine LXC 자체가 이미 준비되어 있다**는 것을 전제로 합니다. 특히 Proxmox CT의 nesting/device/binder/cgroup 관련 설정은 호스트 환경에 따라 별도로 준비해야 합니다.

`alpine_pkgs`는 이 구성에서 사용한 패키지 목록을 기록한 파일입니다. 기본 설치는 패키지를 자동 설치하지 않습니다.

필요 패키지 목록만 확인하려면:

```bash
cat alpine_lxc/alpine_pkgs
```

원할 때만 `-p`를 지정하여 설치할 수 있습니다.

```bash
sudo ./install.sh alpine -p
```

> 패키지 목록은 현재 환경을 재현하기 위한 참고 목록 성격도 포함합니다. 배포판/저장소 상태에 따라 개별 패키지 설치 가능 여부를 먼저 확인하는 것을 권장합니다.

---

## 5. Alpine 설치

Repository root에서:

```bash
sudo ./install.sh alpine -u forumi0721
```

Alpine에서 실행하면 OS 자동 감지도 가능합니다.

```bash
sudo ./install.sh -u forumi0721
```

설치 스크립트는 대상 사용자의 UID/GID/HOME을 확인하여 OpenRC template을 자동 치환합니다.

기본 설치 내용:

```text
/etc/init.d/alpine-cgroup
/etc/init.d/waydroid-sway
/usr/local/bin/waydroid-sway-session
```

그리고 다음 두 서비스를 `default` runlevel에 등록합니다.

```text
alpine-cgroup
waydroid-sway
```

서비스 등록 없이 파일만 설치하려면:

```bash
sudo ./install.sh alpine --no-service -u forumi0721
```

삭제:

```bash
sudo ./install.sh alpine --uninstall
```

---

## 6. Alpine cgroup 준비

`alpine-cgroup`은 LXC 내부의 cgroup v2 root에 프로세스가 남아 child controller 활성화를 막는 상황을 정리합니다.

동작:

1. `/sys/fs/cgroup/init` 생성
2. root cgroup의 process를 `init` leaf로 이동
3. 사용 가능한 `cpu`, `io`, `memory`, `pids` controller를 `cgroup.subtree_control`에 활성화

수동 실행/확인:

```bash
rc-service alpine-cgroup start
cat /sys/fs/cgroup/cgroup.controllers
cat /sys/fs/cgroup/cgroup.subtree_control
```

---

## 7. Alpine 세션 실행 구조

`waydroid-sway` OpenRC 서비스는 설치 시 지정한 일반 사용자로 실행됩니다.

예:

```text
command_user="forumi0721:<primary-group>"
HOME=/home/forumi0721
XDG_RUNTIME_DIR=/run/user/1000
```

세션 스크립트는 필요한 root 작업만 `sudo`로 실행하므로 일반 사용자에게 **비대화형 sudo가 가능해야 합니다.**

확인:

```bash
su -s /bin/sh -c 'sudo -n true' forumi0721
```

exit code가 `0`이어야 자동 기동 중 sudo password prompt에서 멈추지 않습니다.

서비스 시작:

```bash
rc-service alpine-cgroup start
rc-service waydroid-sway start
```

상태:

```bash
rc-service waydroid-sway status
waydroid status
```

정상 기준:

```text
Session:   RUNNING
Container: RUNNING
```

---

## 8. Alpine RRO 위치

Alpine과 Arch 모두 RRO source를 **`/var/lib/waydroid/rro`** 로 통일합니다.

기본 사용자가 `forumi0721`이라면:

```text
/var/lib/waydroid/rro/*.apk
```

예:

```text
/var/lib/waydroid/rro/
├── UserTypesOverlay.apk
└── NavBarOverlay.apk
```

세션 시작 시 다음 위치로 배치됩니다.

```text
source:
  /var/lib/waydroid/rro/<NAME>.apk

Waydroid host filesystem:
  /var/lib/waydroid/overlay/system/product/overlay/<NAME>/<NAME>.apk

Android filesystem:
  /system/product/overlay/<NAME>/<NAME>.apk
```

권한은 directory `0755`, APK `0644`, owner `root:root`로 정리됩니다.

> 과거의 `/root/overlayapk` 또는 `${HOME}/overlayapk` 구성은 사용하지 않습니다. **Alpine/Arch 모두 `/var/lib/waydroid/rro`를 사용합니다.**

---

## 9. Alpine headless session 동작

`waydroid-sway-session`은 다음 순서로 실행됩니다.

1. 이전 WayVNC/Sway/Waydroid session 정리
2. Waydroid LXC config의 `lxc.hook.post-stop = /dev/null` 항목 비활성화
3. Waydroid config/property 적용
4. RRO 배치
5. `/run/user/<uid>` 준비
6. D-Bus session 시작
7. PulseAudio 시작
8. Sway headless compositor 시작
9. headless output을 `1280x720`으로 설정
10. Waydroid container 시작
11. Waydroid user session 시작
12. Android IPv4 확인
13. ADB `5555/tcp` socat forwarding 시작
14. `waydroid show-full-ui` 실행
15. WayVNC 시작
16. 필수 process와 Waydroid container 상태 감시

Sway는 software renderer를 허용하도록 다음 환경을 사용합니다.

```text
WLR_BACKENDS=headless
WLR_HEADLESS_OUTPUTS=1
WLR_LIBINPUT_NO_DEVICES=1
WLR_RENDERER=pixman
WLR_RENDERER_ALLOW_SOFTWARE=1
```

기본 화면 크기:

```text
1280x720
```

---

## 10. Alpine 접속

### VNC

기본값:

```text
0.0.0.0:5900
```

클라이언트에서는 CT의 실제 IP를 사용합니다.

```text
vnc://<ALPINE_CT_IP>:5900
```

환경 변수로 변경할 수 있습니다.

```bash
VNC_BIND=192.168.1.25 VNC_PORT=5901 VNC_FPS=30 \
  /usr/local/bin/waydroid-sway-session
```

### ADB

스크립트가 host/CT IPv4와 Android `eth0` IPv4를 찾아 다음 forwarding을 만듭니다.

```text
<CT_IP>:5555 -> <WAYDROID_ANDROID_IP>:5555
```

외부에서:

```bash
adb connect <ALPINE_CT_IP>:5555
```

필요하면 `ADB_BIND`, `ADB_PORT`, `ANDROID_IP`를 명시할 수 있습니다.

---

## 11. Alpine 로그

```bash
tail -f /var/log/waydroid-sway.log
tail -f /var/log/waydroid-sway.err

tail -f /tmp/sway-waydroid.log
tail -f /tmp/waydroid-session.log
tail -f /tmp/waydroid-ui.log
tail -f /tmp/wayvnc.log
tail -f /tmp/waydroid-socat.log
```

프로세스 확인:

```bash
ps -eo user,pid,ppid,cmd | \
  grep -E 'waydroid|sway|wayvnc|pulseaudio|dbus-daemon|socat' | \
  grep -v grep
```

---

# Arch Linux VM

## 12. Arch 설계 원칙

Arch VM에서는 root와 user session을 분리합니다.

**root/system 영역**

- `/var/lib/waydroid` 설정 변경
- RRO 배치
- `waydroid upgrade -o`
- `waydroid-container.service` 시작 전 prepare 보장

**일반 사용자 영역**

- Sway
- Waydroid session
- Waydroid UI
- WayVNC
- ADB forwarding

이 구조에서는 예전처럼 여러 개의 `sway-headless`, `waydroid-session`, `wayvnc`, `waydroid-adb-forward` user service를 따로 유지하지 않습니다. 현재 repository는 **`waydroid-sway.service` 하나로 통합**합니다.

---

## 13. Arch 설치

기본 설치:

```bash
sudo ./install.sh arch -u forumi0721
```

headless 상시 운영을 위해 linger까지 켜려면:

```bash
sudo ./install.sh arch -u forumi0721 --enable-linger
```

패키지 설치까지 명시적으로 요청할 때만:

```bash
sudo ./install.sh arch -p -u forumi0721 --enable-linger
```

`arch_packages`는 현재 구성에 필요한/사용한 패키지 목록을 기록합니다. 기본 설치는 패키지를 설치하지 않습니다.

시스템 파일만:

```bash
sudo ./install.sh arch --system-only
```

사용자 파일만:

```bash
./arch_vm/install.sh --user-only
```

삭제:

```bash
sudo ./install.sh arch --uninstall -u forumi0721
```

---

## 14. Arch system service

### `waydroid-prepare.service`

```text
/etc/systemd/system/waydroid-prepare.service
/usr/local/sbin/waydroid-prepare
```

`Type=oneshot`, `RemainAfterExit=yes`로 동작하며 `waydroid-container.service`보다 먼저 실행됩니다.

`waydroid-container.service`에는 drop-in이 설치됩니다.

```ini
[Unit]
Requires=waydroid-prepare.service
After=waydroid-prepare.service
```

따라서 container가 시작되기 전에 prepare가 성공해야 합니다.

확인:

```bash
systemctl status waydroid-prepare.service
systemctl cat waydroid-container.service
journalctl -u waydroid-prepare.service -b
```

수동 재적용:

```bash
sudo systemctl restart waydroid-prepare.service
```

---

## 15. Arch `waydroid-prepare`

prepare script가 담당하는 작업:

```text
/var/lib/waydroid/waydroid.cfg
  ├── auto_adb = True
  ├── suspend_action = none
  └── [properties]
      ├── persist.waydroid.suspend = false
      ├── ro.adb.secure = 0
      ├── fw.max_users = 5
      ├── fw.max_running_users = 5
      └── fw.show_multiuserui = 1

/var/lib/waydroid/rro/*.apk
  ↓
/var/lib/waydroid/overlay/system/product/overlay/<NAME>/<NAME>.apk
```

설정이나 RRO가 바뀐 경우에만:

```bash
waydroid upgrade -o
```

를 실행합니다.

---

## 16. Arch RRO 위치

Arch에서 RRO source는 다음으로 고정합니다.

```text
/var/lib/waydroid/rro
```

예:

```text
/var/lib/waydroid/rro/
├── UserTypesOverlay.apk
└── NavBarOverlay.apk
```

배치 결과:

```text
/var/lib/waydroid/overlay/system/product/overlay/
├── UserTypesOverlay/UserTypesOverlay.apk
└── NavBarOverlay/NavBarOverlay.apk
```

Android에서는:

```text
/system/product/overlay/UserTypesOverlay/UserTypesOverlay.apk
/system/product/overlay/NavBarOverlay/NavBarOverlay.apk
```

RRO를 교체한 뒤에는:

```bash
sudo systemctl restart waydroid-prepare.service
sudo systemctl restart waydroid-container.service
```

필요하면 user service도 재시작합니다.

```bash
systemctl --user restart waydroid-sway.service
```

---

## 17. Arch user service

설치 파일:

```text
~/.local/bin/waydroid-sway
~/.config/systemd/user/waydroid-sway.service
```

활성화:

```bash
systemctl --user daemon-reload
systemctl --user enable --now waydroid-sway.service
```

상태:

```bash
systemctl --user status waydroid-sway.service
journalctl --user -u waydroid-sway.service -b
```

로그인 없이 user service를 계속 유지하려면:

```bash
sudo loginctl enable-linger forumi0721
```

확인:

```bash
loginctl show-user forumi0721 -p Linger
```

---

## 18. Arch headless session 동작

`~/.local/bin/waydroid-sway`는 다음 흐름으로 실행됩니다.

1. Sway headless 시작
2. `wayland-*`, `sway-ipc.*.sock` 탐색
3. `waydroid session start`
4. Session RUNNING 대기
5. `waydroid show-full-ui`
6. Sway output 확인
7. WayVNC 시작
8. root `waydroid shell`을 이용해 Android `eth0` IPv4 확인
9. host IPv4 `:5555` → Android IPv4 `:5555` socat forwarding
10. 필수 process를 supervisor loop에서 감시

기본값:

```text
VNC_BIND=0.0.0.0
VNC_PORT=5900
VNC_FPS=15
ADB_PORT=5555
```

Waydroid shell로 Android IP를 읽기 위해 일반 사용자에서 다음 명령이 비대화형으로 가능해야 합니다.

```bash
sudo -n /usr/bin/waydroid shell true
```

---

# Android Multi-user / Clone Profile

## 19. 목표 구성

검증한 최종 구조는 Owner + Clone Profile 3개입니다.

```text
User 0    Owner
User 10   Clone Profile 1
User 11   Clone Profile 2
User 12   Clone Profile 3
```

동일 APK를 여러 번 복사하는 방식이 아니라 Android의 사용자별 package state와 data directory를 분리합니다.

```text
/data/user/0/<package>
/data/user/10/<package>
/data/user/11/<package>
/data/user/12/<package>
```

따라서 같은 앱을 각 profile에서 독립 데이터로 실행할 수 있습니다.

> `10`, `11`, `12`는 목표/검증 구성의 ID입니다. Android가 삭제된 user ID를 즉시 재사용한다는 보장은 없으므로 실제 생성 명령이 반환한 ID를 기준으로 사용합니다.

---

## 20. UserTypesOverlay RRO

Android 13 Waydroid에서 Clone Profile 수를 늘리기 위해 `framework-res.apk`의 다음 resource를 RRO로 override합니다.

```text
xml/config_user_types
```

목표 내용:

```xml
<user-types version="0">
    <profile-type
        name="android.os.usertype.profile.CLONE"
        max-allowed-per-parent="3" />
</user-types>
```

사용한 package name:

```text
kr.stonecold.overlay.usertypes
```

RRO는 정적(static) overlay로 배치합니다. 정상 상태는 `cmd overlay dump`를 기준으로 확인합니다.

```bash
adb shell cmd overlay dump kr.stonecold.overlay.usertypes
```

정상 기준:

```text
mTargetPackageName.....: android
mState.................: STATE_ENABLED
mIsEnabled.............: true
mIsMutable.............: false
```

`cmd overlay list | grep ...` 결과보다 `cmd overlay dump`와 실제 idmap mapping을 우선합니다.

필요하면 root Waydroid shell에서 idmap을 직접 검증할 수 있습니다.

```bash
waydroid shell

rm -f /data/local/tmp/UserTypesOverlay.idmap

idmap2 create \
  --target-apk-path /system/framework/framework-res.apk \
  --overlay-apk-path /system/product/overlay/UserTypesOverlay/UserTypesOverlay.apk \
  --idmap-path /data/local/tmp/UserTypesOverlay.idmap \
  --policy public \
  --policy product

idmap2 dump \
  --idmap-path /data/local/tmp/UserTypesOverlay.idmap
```

검증했던 mapping:

```text
0x01170006 -> 0x7f010000
xml/config_user_types -> xml/config_user_types
```

ADB shell UID 2000에서 `/data/resource-cache` write access 경고가 발생하는 것만으로 RRO 실패라고 판단하지 않습니다.

---

## 21. Clone Profile 생성

현재 사용자 확인:

```bash
adb shell pm list users
adb shell dumpsys user | grep -E 'UserInfo|userType|profileGroupId'
```

Clone Profile 생성:

```bash
adb shell pm create-user \
  --profileOf 0 \
  --user-type android.os.usertype.profile.CLONE \
  User10

adb shell pm create-user \
  --profileOf 0 \
  --user-type android.os.usertype.profile.CLONE \
  User11

adb shell pm create-user \
  --profileOf 0 \
  --user-type android.os.usertype.profile.CLONE \
  User12
```

생성 결과에 표시된 실제 ID를 기록합니다.

예를 들어 실제 ID가 10/11/12라면:

```bash
adb shell am start-user -w 10
adb shell am start-user -w 11
adb shell am start-user -w 12
```

확인:

```bash
adb shell cmd user is-user-running 10
adb shell cmd user is-user-unlocked 10
```

삭제:

```bash
adb shell pm remove-user <USER_ID>
```

> user 삭제 시 해당 user의 계정과 앱 데이터도 삭제됩니다.

---

## 22. Clone Profile에 앱 활성화

APK는 system에 한 번 존재하고 각 Android user마다 설치 상태를 따로 가집니다.

예:

```bash
adb shell pm install-existing --user 10 de.szalkowski.activitylauncher
adb shell pm install-existing --user 11 de.szalkowski.activitylauncher
adb shell pm install-existing --user 12 de.szalkowski.activitylauncher
```

확인:

```bash
adb shell pm list packages --user 10 | grep de.szalkowski.activitylauncher
adb shell pm list packages --user 11 | grep de.szalkowski.activitylauncher
adb shell pm list packages --user 12 | grep de.szalkowski.activitylauncher
```

Launcher Activity를 추측하지 않고 PackageManager에서 확인합니다.

```bash
adb shell cmd package resolve-activity \
  --brief \
  --user 10 \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  de.szalkowski.activitylauncher
```

패키지 기반 실행:

```bash
adb shell am start \
  --user 10 \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  -p de.szalkowski.activitylauncher
```

정확한 component를 알면:

```bash
adb shell am start --user 10 -n '<PACKAGE>/<ACTIVITY>'
```

---

# 검증 및 운영

## 23. 전체 상태 점검

### Waydroid

```bash
waydroid status
```

```text
Session:   RUNNING
Container: RUNNING
```

### Android users

```bash
adb shell pm list users
```

목표 예:

```text
UserInfo{0:Owner:...} running
UserInfo{10:User10:1010} running
UserInfo{11:User11:1010} running
UserInfo{12:User12:1010} running
```

### RRO

```bash
adb shell cmd overlay dump kr.stonecold.overlay.usertypes
adb shell cmd overlay dump kr.stonecold.overlay.navbar
```

### VNC

```text
vnc://<HOST_OR_CT_IP>:5900
```

### ADB

```bash
adb connect <HOST_OR_CT_IP>:5555
adb devices
```

---

## 24. suspend / freeze 관련

과거 Waydroid 1.6.3에서 `suspend_action`이 `stop`이 아닌 모든 경우 freeze로 처리되는 구현을 확인하여 `hardware_manager.py` 직접 패치를 사용한 적이 있습니다.

현재 repository의 **Alpine 스크립트에는 해당 patch code가 주석 처리되어 있으며 자동 수정하지 않습니다.** 현재 운용 설정은 다음을 사용합니다.

```ini
suspend_action = none
persist.waydroid.suspend = false
```

따라서 업데이트 후 container가 예상치 않게 `FROZEN` 상태가 된다면 설치된 Waydroid 버전의 실제 suspend 구현을 다시 확인해야 합니다.

```bash
grep suspend_action /var/lib/waydroid/waydroid.cfg
grep -n -A 8 -B 5 suspend_action \
  /usr/lib/waydroid/tools/services/hardware_manager.py
```

Alpine에서 필요 시:

```bash
sudo lxc-unfreeze -P /var/lib/waydroid/lxc -n waydroid
```

---

## 25. Troubleshooting

### `Cannot add more profiles of type ... CLONE`

```bash
adb shell cmd overlay dump kr.stonecold.overlay.usertypes
adb shell pm list users
```

확인할 것:

- `UserTypesOverlay.apk`가 올바른 RRO source directory에 있는지
- Android에서 overlay가 `STATE_ENABLED`인지
- `config_user_types` idmap이 생성되는지
- 기존 Clone Profile 개수가 이미 limit에 도달했는지
- RRO 교체 후 Waydroid container가 완전히 재시작되었는지

### Activity `Error type 3`

Activity 이름을 추측하지 말고:

```bash
adb shell cmd package resolve-activity \
  --brief \
  --user <USER_ID> \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  <PACKAGE>
```

조회되지 않으면:

```bash
adb shell pm install-existing --user <USER_ID> <PACKAGE>
adb shell am start-user -w <USER_ID>
```

### Alpine service가 반복 재시작

```bash
rc-service waydroid-sway status
tail -n 200 /var/log/waydroid-sway.err
tail -n 100 /tmp/waydroid-session.log
tail -n 100 /tmp/wayvnc.log
tail -n 100 /tmp/waydroid-socat.log
```

`supervise-daemon`은 실패한 session을 재시작하므로 원인을 고치기 전에는 로그가 반복될 수 있습니다.

### Arch user service 실패

```bash
systemctl --user status waydroid-sway.service
journalctl --user -u waydroid-sway.service -b
systemctl status waydroid-container.service
journalctl -u waydroid-prepare.service -b
```

특히 확인:

```bash
sudo -n /usr/bin/waydroid shell true
```

### WayVNC는 떠 있는데 화면이 없음

```bash
ls -l "$XDG_RUNTIME_DIR"/wayland-*
ls -l "$XDG_RUNTIME_DIR"/sway-ipc.*.sock
swaymsg -t get_outputs
waydroid status
```

---

# 백업 / 복구

## 26. Repository로 관리할 파일

이 repository 자체에서 관리하는 핵심 파일은 다음입니다.

```text
install.sh
alpine_lxc/
arch_vm/
README.md
```

즉 서비스 정의와 실행 스크립트는 서버에서 직접 수정하기보다 repository 원본을 수정한 뒤 installer로 다시 배포하는 방식을 권장합니다.

---

## 27. Runtime에서 별도로 백업할 항목

Repository에 포함되지 않는 실제 Waydroid 상태 중 필요한 항목만 별도 백업합니다.

### 공통

```text
/var/lib/waydroid/waydroid.cfg
/var/lib/waydroid/waydroid.prop          # 존재/사용 시
/var/lib/waydroid/overlay/               # 생성된 overlay tree가 필요할 때
```

### Alpine

```text
/var/lib/waydroid/rro/                   # Alpine / Arch 공통 RRO 원본
/etc/sudoers.d/...                       # Waydroid용 sudo rule을 별도 구성했다면
```

### Android 사용자/앱 데이터까지 보존해야 하는 경우

Waydroid 전체 state는 `/var/lib/waydroid` 아래에 있으므로 단순 service 파일 백업과 별개로 취급합니다. Android user 10/11/12의 앱 데이터가 중요하다면 `/var/lib/waydroid`를 포함한 별도 백업/스냅샷 정책을 사용해야 합니다.

> `pm remove-user`는 해당 Android user 데이터를 삭제하므로 multi-user 재구성 전에 snapshot/backup을 먼저 확인합니다.

---

# 설치 옵션

## 28. 통합 installer

```text
Usage: ./install.sh [TARGET] [OPTIONS]

TARGET
  alpine
  arch

COMMON
  -p, --install-pkgs
  -u, --user <NAME>
  --uninstall
  -h, --help
```

TARGET을 생략하면 `/etc/os-release`로 자동 감지합니다.

```bash
sudo ./install.sh
sudo ./install.sh -u forumi0721
sudo ./install.sh alpine -u forumi0721
sudo ./install.sh arch -u forumi0721 --enable-linger
```

환경별 추가 옵션:

| 옵션 | Alpine | Arch | 설명 |
|---|:---:|:---:|---|
| `-p`, `--install-pkgs` | O | O | 목록의 package 설치. 기본값은 설치하지 않음 |
| `-u`, `--user NAME` | O | O | session 대상 사용자 |
| `--no-service` | O | O | service 등록/enable 생략 |
| `--uninstall` | O | O | 설치 파일 및 service 제거 |
| `--system-only` | - | O | Arch system component만 설치 |
| `--user-only` | - | O | Arch user component만 설치 |
| `--enable-linger` | - | O | Arch user linger 활성화 |

---

# 현재 기준 핵심 정리

## Alpine LXC

```text
OpenRC + supervise-daemon
RRO source: /var/lib/waydroid/rro
RRO target: /var/lib/waydroid/overlay/system/product/overlay
Session: 일반 사용자
Container 제어: sudo/root
Sway: headless + pixman
VNC: :5900
ADB: host/CT :5555 -> Android :5555
```

## Arch VM

```text
system:
  waydroid-prepare.service
  -> waydroid-container.service

user:
  waydroid-sway.service

RRO source: /var/lib/waydroid/rro
RRO target: /var/lib/waydroid/overlay/system/product/overlay
VNC: :5900
ADB: host :5555 -> Android :5555
```

## Android

```text
Owner + Clone Profile x3
fw.max_users = 5
fw.max_running_users = 5
fw.show_multiuserui = 1
UserTypesOverlay: max-allowed-per-parent = 3
```

이 구성을 현재 `way` repository의 기준 상태로 사용합니다.
