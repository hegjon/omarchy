#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const menuQml = fs.readFileSync(path.join(root, 'shell/plugins/menu/Menu.qml'), 'utf8')
const body = (pattern) => {
  const match = pattern.exec(menuQml)
  assert(match, `Menu.qml defines ${pattern}`)
  return match[1]
}

// The open path shows the card first; the guard batch and the icon rescan,
// which together fork ~150 processes, follow once the card is on screen.
const openBody = body(/function openExistingMenu\(initialMenu\) \{([\s\S]*?)\n  \}/)
assert(!/evaluateGuards\(\)/.test(openBody), 'opening a menu does not start the guard batch itself')
assert(!/refreshIcons\(\)/.test(openBody), 'opening a menu does not start the icon rescan itself')
assert(/opened = true[\s\S]*scheduleOpenWork\(\)/.test(openBody), 'opening a menu schedules both once it is open')

const afterReveal = Number(body(/readonly property int afterReveal: (\d+)/))
const fallback = Number(body(/readonly property int fallback: (\d+)/))
assert(afterReveal > 0 && afterReveal < fallback, 'the reveal delay is short and the fallback longer')

const schedule = new Function('root', 'panel', 'openWorkTimer', body(/function scheduleOpenWork\(\) \{([\s\S]*?)\n  \}/))
const cancel = new Function('root', 'openWorkTimer', body(/function cancelOpenWork\(\) \{([\s\S]*?)\n  \}/))
const run = new Function('root', 'openWorkTimer', body(/function runOpenWork\(\) \{([\s\S]*?)\n  \}/))
const revealed = new Function('contentRevealed', 'root', 'openWorkTimer',
  body(/onContentRevealedChanged: (if \(contentRevealed && root\.openWorkPending\) \{[\s\S]*?\n    \})/))

const timer = () => ({ afterReveal, fallback, interval: 0, running: false, restarts: 0,
  restart() { this.running = true; this.restarts++ }, stop() { this.running = false } })
const shell = () => {
  const r = { opened: true, openWorkPending: false, guards: 0, icons: 0,
    evaluateGuards() { r.guards++ }, appLibrary: { refreshIcons() { r.icons++ } } }
  return r
}

let fake = shell(), t = timer()
schedule(fake, { contentRevealed: false }, t)
assert(fake.openWorkPending && t.running, 'scheduling arms the timer')
assertEqual(t.interval, fallback, 'a window that has not revealed waits on the fallback')
revealed(true, fake, t)
assertEqual(t.interval, afterReveal, 'the reveal shortens the wait to one frame after it')
assertEqual(t.restarts, 2, 'the reveal restarts the timer')
run(fake, t)
assertDeepEqual([fake.guards, fake.icons, t.running, fake.openWorkPending], [1, 1, false, false],
  'the timer runs the guard batch and the icon rescan once, then disarms')
run(fake, t)
assertEqual(fake.guards, 1, 'work that already ran does not run again')

fake = shell(); t = timer()
schedule(fake, { contentRevealed: true }, t)
assertEqual(t.interval, afterReveal, 'opening onto an already revealed window waits one frame only')
revealed(false, fake, t)
assertEqual(t.restarts, 1, 'losing the reveal does not touch the timer')

fake = shell(); t = timer()
schedule(fake, { contentRevealed: false }, t)
fake.opened = false
cancel(fake, t)
assert(!t.running && !fake.openWorkPending, 'closing cancels work that has not started')
run(fake, t)
assertEqual(fake.guards, 0, 'a cancelled open runs nothing')

fake = shell(); t = timer()
schedule(fake, { contentRevealed: false }, t)
fake.opened = false
run(fake, t)
assertEqual(fake.guards, 0, 'a menu closed before the timer fires runs nothing')
assert(!fake.openWorkPending, 'and nothing stays pending for the next open')

// The guard script only changes with the items, which are replaced whole,
// so it is built once per item set rather than on every open.
const evaluate = new Function('root', 'guardProc', 'MenuModel', body(/function evaluateGuards\(\) \{([\s\S]*?)\n  \}/))
let builds = 0
const MenuModel = { guardScript(items) { builds++; return items.script } }
const itemsA = { script: 'echo a:w:1' }
fake = { items: itemsA, guardScriptItems: null, guardScript: '', guardsPending: false }
const guardProc = { running: false, collected: '', command: null }
// Each run starts the batch; pretend it exited before the next evaluation.
const evaluateOnce = () => { evaluate(fake, guardProc, MenuModel); guardProc.running = false }
evaluateOnce()
evaluateOnce()
assertEqual(builds, 1, 'the guard script is built once for the same items')
assertDeepEqual(guardProc.command.slice(0, 5), ['nice', '-n', '10', 'bash', '-lc'], 'the guard batch yields to the shell and the compositor')
assertEqual(guardProc.command[5], 'echo a:w:1', 'the cached script is what runs')
fake.items = { script: 'echo b:w:1' }
evaluateOnce()
assertEqual(builds, 2, 'replaced items rebuild the guard script')
assertEqual(guardProc.command[5], 'echo b:w:1', 'the rebuilt script is what runs')
fake.items = { script: '' }
evaluateOnce()
assertDeepEqual(fake.whenResults, {}, 'items without guards clear the answers without running a batch')
JS
