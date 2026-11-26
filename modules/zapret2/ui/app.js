'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';
'require view.zapret2.main as main';
'require view.zapret2.service as serviceTab';
'require view.zapret2.scripts as scriptsTab';
'require view.zapret2.lists as listsTab';
'require view.zapret2.autohostlist as autohostlistTab';
'require view.zapret2.blockcheck as blockcheckTab';
'require view.zapret2.rr_blockcheck2 as finderTab';
'require view.zapret2.payloadgen as payloadgenTab';
'require view.zapret2.debuglog as debuglogTab';
var _finderAvailable = false;
var _payloadgenAvailable = false;
function load() {
	return Promise.all([
		uci.load('zapret2'),
		main.loadServiceStatus(),
		main.loadListFiles(),
		main.loadBlobFiles(),
		main.loadLuaFiles(),
		main.loadVersion(),
		fs.exec('/opt/zapret2/zapret2-finder', ['--device-check']).then(function(res) {
			_finderAvailable = (res && res.code === 0);
		}).catch(function() {
			_finderAvailable = false;
		}),
		fs.exec('/opt/zapret2/zapret2-payloadgen', ['--device-check']).then(function(res) {
			_payloadgenAvailable = (res && res.code === 0);
		}).catch(function() {
			_payloadgenAvailable = false;
		}),
		L.resolveDefault(uci.load('network'))
	]);
}
function render(data) {
	var initStatus = data[1];
	var listFiles = data[2];
	var blobFiles = data[3];
	var luaFiles = data[4];
	var version = data[5];
	main.injectStyles();
	return main.syncFilesWithUCI(listFiles, blobFiles, luaFiles).then(function() {
		var description = _('DPI bypass tool with Lua scripting support.');
		if (version) {
			description += ' ' + _('Version') + ': ' + version;
		}
		var m = new form.Map('zapret2');
		m.tabbed = true;
		serviceTab.createServiceTab(m, initStatus);
		scriptsTab.createScriptsTab(m);
		listsTab.createListsTab(m);
		autohostlistTab.createAutohostlistTab(m);
		blockcheckTab.createBlockcheckTab(m);
		if (_finderAvailable) {
			finderTab.createFinderTab(m);
		}
		if (_payloadgenAvailable) {
			payloadgenTab.createPayloadgenTab(m);
		}
		debuglogTab.createDebuglogTab(m);
		main.initControllers();
		var origSave = m.save.bind(m);
		m.save = function() {
			main.reorderSections();
			return origSave();
		};
		var servicePanel = serviceTab.renderServiceControls(initStatus);

		return m.render().then(function(mapEl) {
			var tabMenu = mapEl.querySelector('.cbi-tabmenu');
			if (tabMenu) {
				tabMenu.querySelectorAll('li a').forEach(function(link) {
					if (link.textContent === 'strategy') {
						link.textContent = _('Zapret2');
					}
				});
			}
			return E('div', {}, [
				E('h2', {}, _('Zapret2')),
				E('div', { class: 'cbi-map-descr' }, description),
				servicePanel,
				mapEl
			]);
		});
	});
}

function safeConfigAction(args) {
	return fs.exec('/usr/lib/ows/zapret2-safe.sh', args).then(function(result) {
		if (result.code !== 0)
			throw new Error(result.stderr || result.stdout || 'Операция Zapret2 не выполнена.');
		window.location.reload();
	}).catch(function(error) {
		ui.addNotification(null, E('pre', { style: 'white-space:pre-wrap' }, error.message), 'error');
	});
}

return view.extend({
	load: load,
	render: function(data) {
		return render(data);
	},
	handleSaveApply: function(event) {
		return this.handleSave(event).then(function() {
			return safeConfigAction(['apply', L.env.sessionid]);
		});
	},
	handleReset: function() {
		return safeConfigAction(['discard', L.env.sessionid]);
	},
	handleRestore: function() {
		if (window.confirm('Восстановить предыдущую конфигурацию Zapret2 и сбросить черновик?'))
			return safeConfigAction(['restore', L.env.sessionid]);
	},
	addFooter: function() {
		var disabled = !L.hasViewPermission() || null;
		return E('div', { class: 'cbi-page-actions' }, [
			E('button', { type: 'button', id: 'zapret2-safe-apply', class: 'cbi-button cbi-button-apply important',
				disabled: disabled, click: ui.createHandlerFn(this, 'handleSaveApply') }, _('Save & Apply')),
			' ',
			E('button', { type: 'button', class: 'cbi-button cbi-button-save', disabled: disabled,
				click: ui.createHandlerFn(this, 'handleSave') }, _('Save')),
			' ',
			E('button', { type: 'button', class: 'cbi-button cbi-button-reset', disabled: disabled,
				click: ui.createHandlerFn(this, 'handleReset') }, 'Сбросить черновик'),
			' ',
			E('button', { type: 'button', class: 'cbi-button', disabled: disabled,
				click: ui.createHandlerFn(this, 'handleRestore') }, 'Восстановить предыдущий конфиг')
		]);
	}
});
