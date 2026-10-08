"""Translated setup keeps dashboard routes, the voice choice and recommendation keys."""
import json
import os
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from playwright.sync_api import sync_playwright, expect

APP = Path(__file__).resolve().parents[1]
ROOT = APP / 'remote-ui'
english = {k: v for p in (APP / 'l10n/source').glob('*.arb') for k, v in json.loads(p.read_text()).items() if not k.startswith('@')}
translated = {k: 'TEST ' + v for k, v in english.items()}
if os.environ.get('KS_TEST_SPANISH'):
    translated = {k: v for p in (APP.parents[1] / 'kiosk-satellite-localization/translations/es').glob('*.arb') for k, v in json.loads(p.read_text()).items() if not k.startswith('@')}
ids = json.loads((APP / 'l10n/setup_text.json').read_text())
ha_ids = json.loads((APP / 'l10n/ha_text.json').read_text())
commands = []
patches = []
views = [dict(title='Choose a view', route='original'), dict(title='<b>Original view</b>', route='second')]
dashboards = [dict(url_path='raw-dashboard', title='Choose a dashboard'), dict(url_path='other-dashboard', title='<b>Original dashboard</b>')]

def api(route):
    path = route.request.url.split('/api/', 1)[1]
    params = route.request.post_data_json or {}
    if path == 'settings':
        patches.append(params)
        return route.fulfill(json=dict(ok=True))
    name = path.removeprefix('commands/')
    commands.append((name, params))
    result = {'haListDashboards': dashboards, 'haListDashboardViews': views, 'getSystemPermissions': {}}.get(name, {})
    route.fulfill(json=dict(ok=True, data=result))

class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport=dict(width=1200, height=1200))
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        html = (ROOT / 'index.html').read_text().replace('<script type="module" src="static/main.js?v=__KSV__"></script>', '')
        page.route(base + '/', lambda r: r.fulfill(body=html, content_type='text/html'))
        page.route('**/static/catalogs.js', lambda r: r.fulfill(body='export const catalogs = ' + json.dumps({'en': english, 'es': translated}) + ';', content_type='text/javascript'))
        page.route('**/api/**', api)
        page.goto(base + '/')
        page.evaluate("""async views => {
          const c=await import('/static/core.js');c.showView('wizard');
          (await import('/static/localization.js')).setLanguagePreference('es');
          const {wizard}=await import('/static/app.js');
          await (await import('/static/dashboard_picker.js')).loadDashboards();
          Object.assign(wizard,{i:2,base:'http://ha.example',dashboardPath:'raw-dashboard/original'});
          const w=await import('/static/wizard.js');wizard.steps=w.wizardSteps();w.wizardRender();
        }""", views)
        root = page.locator('#wizardBody')
        # Copy not in the catalogs yet reads in English.
        def label(en): return translated[ids[en]] if en in ids else en
        def ha_label(en): return translated[ha_ids[en]] if en in ha_ids else en
        def state(): return page.evaluate("async()=>{const {wizard:w}=await import('/static/app.js');return {view:w.dashboardPath,voice:w.voice,rec:w.rec};}")
        def language(value):
            page.evaluate("async language=>{(await import('/static/localization.js')).setLanguagePreference(language);const {wizard}=await import('/static/app.js');const w=await import('/static/wizard.js');wizard.steps=w.wizardSteps();w.wizardRender();}", value)
        expect(page.locator('#wizardTitle')).to_have_text(label('Choose a dashboard'))
        # The picker inline: names from Home Assistant stay as they are,
        # the picker's own wording follows the language.
        expect(root.locator('.dp-dash.active .dp-title')).to_have_text('Choose a dashboard')
        expect(root.locator('.dp-search')).to_have_attribute('placeholder', ha_label('Search dashboards and views'))
        expect(root.locator('.dp-tile.picked .dp-title')).to_have_text('Choose a view')
        root.locator('.dp-tile', has_text='<b>Original view</b>').click()
        assert state()['view'] == 'raw-dashboard/second'
        expect(root.locator('.dp-tile.picked .dp-title')).to_have_text('<b>Original view</b>')
        before = len(commands)
        language('en'); expect(page.locator('#wizardTitle')).to_have_text('Choose a dashboard')
        language('es'); expect(page.locator('#wizardTitle')).to_have_text(label('Choose a dashboard'))
        assert state()['view'] == 'raw-dashboard/second'
        assert len(commands) == before
        root.locator('.dp-dash', has_text='<b>Original dashboard</b>').click()
        root.locator('.dp-tile', has_text='Choose a view').click()
        assert state()['view'] == 'other-dashboard/original'
        assert root.locator('b').count() == 0
        page.locator('#wizardNext').click()
        # The kiosk is its own satellite, so the step always shows. Detection
        # runs once when it does, only to offer the migration, and finding
        # no integration leaves the satellite's basics without the offer.
        expect(page.locator('#wizardTitle')).to_have_text('Voice Satellite')
        expect(root.get_by_text(label('Wake word engine'), exact=True)).to_be_visible()
        assert [name for name, _ in commands].count('haDetectVoiceSatellite') == 1
        assert page.evaluate("async()=>(await import('/static/app.js')).wizard.vsInstalled") is False
        expect(root.get_by_role('button', name=label('Migrate'), exact=True)).to_have_count(0)
        assert state()['voice'] is True
        expect(root).to_contain_text(label('After setup, add this kiosk in Home Assistant under Settings, Devices & services, where it shows up as discovered.'))
        master = root.locator('.row').filter(has=page.get_by_text(label('Apply all recommended settings'), exact=True))
        master.locator('label.switch').click()
        assert not any(state()['rec'].values())
        target = root.locator('.row').filter(has=page.get_by_text(label('Keep listening in the background'), exact=True))
        target.locator('label.switch').click()
        assert state()['rec']['wake_word.background'] is True
        selected = state()
        language('en'); language('es')
        assert state() == selected
        assert not patches
        assert root.locator('b').count() == 0
        page.set_viewport_size(dict(width=390, height=1000))
        assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
        page.locator('#wizardBack').click()
        expect(page.locator('#wizardTitle')).to_have_text(label('Choose a dashboard'))
        page.locator('#wizardNext').click()
        expect(page.locator('#wizardTitle')).to_have_text('Voice Satellite')
        assert state() == selected
        assert [name for name, _ in commands].count('haDetectVoiceSatellite') == 1
        # Off, background listening goes with it.
        voice = root.locator('.row').filter(has=page.get_by_text(label('Enable Voice Satellite'), exact=True))
        voice.locator('label.switch').click()
        assert state()['voice'] is False
        expect(root.get_by_text(label('Keep listening in the background'), exact=True)).to_have_count(0)
        voice.locator('label.switch').click()
        assert state()['voice'] is True
        # Empty data keeps translated guidance.
        dashboards.clear()
        page.evaluate("async()=>{await (await import('/static/dashboard_picker.js')).loadDashboards();const {wizard:w}=await import('/static/app.js');w.i=2;w.dashboardPath=null;(await import('/static/wizard.js')).wizardRender();}")
        expect(root).to_contain_text(ha_label('No dashboards yet'))
        before = len(commands)
        page.locator('#wizardNext').click()
        expect(page.locator('#wizardError')).to_contain_text(label('Select a dashboard'))
        assert len(commands) == before
        page.evaluate("async()=>{const {wizard:w}=await import('/static/app.js');w.i=4;w.dashboardPath='other-dashboard/original';(await import('/static/wizard.js')).wizardRender();}")
        # Check the existing final-step write without resetting a real device.
        page.route(base + '/', lambda r: r.fulfill(body='<p>Setup complete</p>', content_type='text/html'))
        with page.expect_navigation():
            page.evaluate("async()=>{const {wizard}=await import('/static/app.js');await wizard.steps.at(-1).next();}")
        chosen, start = patches[-2:]
        assert chosen['voice.enabled'] is True and chosen['esphome.enabled'] is True
        assert 'ha.satellite_entity' not in chosen
        assert {k:chosen[k] for k in selected['rec']} == selected['rec']
        assert start == {'browser.start_url':'http://ha.example/other-dashboard/original'}
        assert not errors, errors
        browser.close()
    print('Setup dashboard and Voice Satellite browser checks passed')
finally:
    server.shutdown()
