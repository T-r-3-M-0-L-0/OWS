'use strict';
'require view';
'require rpc';
'require poll';
'require request';
'require session';
'require ui';
'require view.ows-templates as templates';
'require view.ows-zapret as zapret';
'require view.ows-zapret-tools as zapretTools';
'require view.ows-zapret-tactics as zapretTactics';
'require view.ows-dns as dns';
'require view.ows-doh as doh';
'require view.ows-domain-search as domainSearch';
'require view.ows-legacy-cleanup as legacyCleanup';
'require view.ows-service-status as serviceStatus';
'require view.ows-instructions as instructions';

var status = rpc.declare({ object: 'ows', method: 'status' });
var jobStatus = rpc.declare({ object: 'ows', method: 'job_status', params: ['job'] });
var jobOutput = rpc.declare({ object: 'ows', method: 'job_output', params: ['job'] });
var moduleList = rpc.declare({ object: 'ows', method: 'module_list' });
var moduleStatus = rpc.declare({ object: 'ows', method: 'module_status', params: ['id'] });
var modulePreview = rpc.declare({ object: 'ows', method: 'module_preview', params: ['manifest'] });
var moduleAttach = rpc.declare({ object: 'ows', method: 'module_attach', params: ['manifest'] });
var moduleLink = rpc.declare({ object: 'ows', method: 'module_link', params: ['name', 'source'] });
var moduleInstall = rpc.declare({ object: 'ows', method: 'module_install', params: ['id'] });
var moduleLinks = rpc.declare({ object: 'ows', method: 'module_links' });

var labels = {
    idle: _('Нет операций'),
    queued: _('В очереди'),
    waiting: _('Ожидает освобождения ресурсов'),
    validating: _('Проверка конфигурации'),
    applying: _('Применение'),
    applied: _('Применено'),
    invalid_config: _('Проверка конфигурации не пройдена'),
    config_changed: _('Конфигурация изменилась. Обновите редактор'),
    config_busy: _('Идёт проверка Zapret2 по расписанию'),
    snapshot_failed: _('Не удалось создать снимок'),
    rolling_back: _('Откат'),
    rolled_back: _('Предыдущая конфигурация восстановлена'),
    rollback_failed: _('Ошибка отката. Требуется вмешательство'),
    interrupted: _('Операция прервана'),
    done: _('Операция завершена'),
    operation_failed: _('Ошибка операции')
};

var stgwsActions = {
    check: _('Проверка MTProto'),
    start: _('Запуск'),
    stop: _('Остановка'),
    enable: _('Включение автозапуска'),
    disable: _('Отключение автозапуска'),
    restart: _('Перезапуск'),
    reconfigure: _('Подбор домена'),
    route_smart: _('Умная карта'),
    route_save: _('Сохранение карты'),
    route_restore: _('Восстановление карты'),
    install: _('Установка пакета'),
    update: _('Обновление пакета'),
    reinstall: _('Переустановка пакета'),
    remove: _('Удаление пакета')
};

function statusLabel(result, template) {
    var label = labels[result.phase] || _('Статус неизвестен');
    if (result.phase === 'waiting') {
        var waits = {
            dns: _('Ожидает завершения операции с DNS'),
            firewall: _('Ожидает освобождения файрвола и маршрутов'),
            telegram: _('Ожидает завершения операции с ТГ-прокси'),
            strategy: _('Ожидает завершения проверки Zapret2'),
            strategy_recovery: _('Ожидает восстановления Zapret2 после проверки'),
            stgws_probe: _('Ожидает завершения проверок карты sTGWS'),
            dns_recovery: _('Ожидает восстановления DNS'),
            memory: _('Для второй проверки пока недостаточно ОЗУ'),
            tmp_space: _('Для второй проверки пока недостаточно места в /tmp')
        };
        label = waits[result.wait_reason] || label;
    }
    if (template && template.jobActions && Object.prototype.hasOwnProperty.call(template.jobActions, result.action)) {
        return (template.jobName || result.kind) + ' · ' + template.jobActions[result.action] + ' · ' + label;
    }
    if (result.kind === 'zapret-module') {
        var parts = (result.action || '').split(':');
        var operation = {
            download:_('Скачивание пакетов'), install:_('Установка пакетов'), 'install-latest':_('Установка пакетов'),
            'import-resources':_('Импорт стратегий и ресурсов'),
            'nfq-optimize':_('Оптимизация NFQUEUE'), 'nfq-rollback':_('Восстановление фильтров NFQUEUE'),
            start:_('Запуск'), stop:_('Остановка'), restart:_('Перезапуск'),
            enable:_('Включение автозапуска'), disable:_('Выключение автозапуска'),
            'compare-start':_('Сравнение стратегий'), 'compare-stop':_('Остановка сравнения'),
            'schedule-set':_('Настройка расписания')
        }[parts[1]] || _('Конструктор');
        return (parts[0] === 'zapret2' ? 'Zapret2' : 'Zapret') + ' · ' + operation + ' · ' + label;
    }
    if (result.kind === 'dns') return _('Проверка DNS') + ' · ' + label;
    if (result.kind === 'install-module') return result.action + ' · ' + _('Установка пакетов') + ' · ' + label;
    if (result.kind === 'cleanup') return _('Очистка остатков Zapret-Manager') + ' · ' + label;
    if (result.kind === 'doh') return 'DoH · ' + (result.action === 'install' ? _('Установка пакетов') + ' · ' : '') + label;
    if (result.kind === 'system') {
        var systemNames = {quic:_('Блокировка QUIC'),ipv6:_('IPv6 в Zapret'),zram:'ZRAM',
            takeover:_('Передача системных модулей'),net:_('Сетевые исключения')};
        return (systemNames[(result.action || '').split(':')[0]] || _('Система')) + ' · ' + label;
    }
    if (result.kind === 'adblock') return (result.action === 'install-fast' ? _('Установка AdBlock Fast') :
        _('Блокировка рекламы')) + ' · ' + label;
    if (result.kind && result.kind !== 'stgws' && result.kind !== 'zapret2') {
        var operation = result.action === 'diag' ? _('Диагностика') :
            result.action === 'prepare-migration' ? _('Подготовка переноса') :
            result.action === 'check-handover' ? _('Проверка готовности к передаче') :
            result.action === 'refresh-draft-subscription' ? _('Обновление подписки в манифесте') :
            result.action === 'test-draft-lists' ? _('Проверка обновления списков') :
            result.action === 'takeover' ? _('Передача управления') :
            result.action === 'refresh-live-lists' ? _('Обновление рабочих списков') :
            result.action === 'refresh-live-subscription' ? _('Обновление рабочей подписки') :
            result.action === 'edit' ? (result.kind === 'steer' ? _('Редактирование манифеста') : _('Изменение конфигурации')) :
            (result.action || '').indexOf('preview-draft:') === 0 ? _('Проверка манифеста') :
            (result.action || '').indexOf('apply-draft:') === 0 ? _('Применение манифеста') :
            (result.action || '').indexOf('probe:') === 0 ? _('Проверка узла') :
            (result.action || '').indexOf('probe-all:') === 0 ? _('Проверка всех узлов') :
            (result.action || '').indexOf('list-preview:') === 0 ? _('Просмотр состава сервиса') : _('Проверка подписки');
        return result.kind + ' · ' + operation + ' · ' + label;
    }
    if (result.kind !== 'stgws') return label;
    var action = stgwsActions[result.action] || _('Настройки');
    if (result.action === 'check' && result.phase === 'operation_failed') {
        return _('sTGWS · Проверка MTProto не пройдена');
    }
    return 'sTGWS · ' + action + ' · ' + label;
}

function createTabs(name, tabs, initial, onChange) {
    var links = [];
    var panels = [];
    var active = -1;
    var menu = E('ul', { class: 'cbi-tabmenu ows-tabmenu', role: 'tablist', 'aria-label': name });

    function select(index, focus) {
        if (index === active) {
            if (focus) links[index].focus();
            return;
        }
        active = index;
        links.forEach(function(link, i) {
            var selected = i === index;
            link.parentNode.className = selected ? 'cbi-tab' : 'cbi-tab-disabled';
            link.setAttribute('aria-selected', String(selected));
            link.tabIndex = selected ? 0 : -1;
            panels[i].hidden = !selected;
        });
        if (focus) links[index].focus();
        if (tabs[index].activate) tabs[index].activate();
        if (onChange) onChange(tabs[index].id);
    }

    tabs.forEach(function(tab, index) {
        var id = 'ows-tab-' + tab.id;
        var panel = E('section', { id: id + '-panel', role: 'tabpanel', 'aria-labelledby': id }, tab.content);
        var link = E('a', { id: id, href: '#' + panel.id, role: 'tab', 'aria-controls': panel.id }, tab.label);
        link.addEventListener('click', function(event) {
            event.preventDefault();
            select(index, false);
        });
        link.addEventListener('keydown', function(event) {
            var next;
            switch (event.key) {
            case 'ArrowRight': next = (index + 1) % tabs.length; break;
            case 'ArrowLeft': next = (index + tabs.length - 1) % tabs.length; break;
            case 'Home': next = 0; break;
            case 'End': next = tabs.length - 1; break;
            case ' ': next = index; break;
            default: return;
            }
            event.preventDefault();
            select(next, true);
        });
        links.push(link);
        panels.push(panel);
        menu.appendChild(E('li', { role: 'presentation' }, link));
    });

    var content = E('div', {}, [menu].concat(panels));
    var start = typeof initial === 'string' ? tabs.findIndex(function(tab) { return tab.id === initial; }) : initial;
    select(start > 0 ? start : 0, false);
    return {
        content: content,
        select: function(index) { select(index, true); },
        selectId: function(id) {
            var index = tabs.findIndex(function(tab) { return tab.id === id; });
            if (index < 0) return false;
            select(index, true);
            return true;
        },
        activate: function() { if (tabs[active].activate) tabs[active].activate(); },
        selectedId: function() { return tabs[active].id; }
    };
}

function field(id, label, input) {
    return E('div', { class: 'ows-field' }, [E('label', { for: id }, label), input]);
}

function entrySource(entry, label) {
    if (!/^https:\/\//.test(entry.source || '')) return null;
    return E('a', { href: entry.source, target: '_blank', rel: 'noopener noreferrer' }, label || _('Открыть источник'));
}

function adapterTab(entry) {
    var state = E('p', { 'aria-live': 'polite' });
    function loadStatus() {
        state.textContent = _('Читаем состояние службы');
        return moduleStatus(entry.id).then(function(result) {
            var states = { running: _('Работает'), stopped: _('Остановлена'), unknown: _('Состояние недоступно') };
            state.textContent = result.error || states[result.state] || _('Состояние недоступно');
        }, function() {
            state.textContent = _('Не удалось прочитать состояние службы');
        });
    }
    var refresh = E('button', { type: 'button', class: 'cbi-button' }, _('Обновить статус'));
    refresh.addEventListener('click', loadStatus);
    var detail = createTabs(_('Разделы модуля'), [
        { id: 'module-' + entry.id + '-status', label: _('Состояние'), content: [
            E('p', {}, [_('Служба'), ' ', E('code', {}, entry.service)]), state, refresh
        ] },
        { id: 'module-' + entry.id + '-source', label: _('Адаптер'), content: [
            E('p', {}, [_('Версия'), ' ', entry.version]), E('p', {}, entry.description || ''),
            entrySource(entry)
        ].filter(Boolean) }
    ]);
    return {
        id: 'module-' + entry.id, label: entry.name, activate: loadStatus,
        content: [E('h3', {}, entry.name), detail.content]
    };
}

function adapterCatalog(onChange) {
    var list = E('div');
    var notice = E('p', { 'aria-live': 'polite' });
    var previewPane = E('div');
    var name = E('input', { id: 'ows-link-name', class: 'cbi-input-text', type: 'text', maxlength: 64 });
    var source = E('input', { id: 'ows-link-url', class: 'cbi-input-text', type: 'url', maxlength: 512 });
    var file = E('input', { id: 'ows-manifest', type: 'file', accept: '.json,application/json' });
    var save = E('button', { class: 'cbi-button', type: 'button' }, _('Сохранить ссылку'));
    var inspect = E('button', { class: 'cbi-button', type: 'button' }, _('Проверить манифест'));
    var refresh = E('button', { class: 'cbi-button', type: 'button' }, _('Обновить каталог'));

    function load() {
        refresh.disabled = true;
        return moduleList().then(function(result) {
            if (result.error) notice.textContent = result.error;
            else onChange(result.entries || [], result.vpn_drivers || {}, result.installed || {});
        }, function() {
            notice.textContent = _('Не удалось прочитать каталог');
        }).finally(function() { refresh.disabled = false; });
    }

    function store(request, button, message) {
        button.disabled = true;
        return request.then(function(result) {
            notice.textContent = result.error || message;
            if (!result.id) return;
            previewPane.replaceChildren();
            return load();
        }, function() {
            notice.textContent = _('Не удалось сохранить. Проверьте права на запись.');
        }).finally(function() { button.disabled = false; });
    }

    refresh.addEventListener('click', load);
    save.addEventListener('click', function() {
        store(moduleLink(name.value.trim(), source.value.trim()), save, _('Ссылка сохранена'));
    });
    file.addEventListener('change', function() { previewPane.replaceChildren(); });
    inspect.addEventListener('click', function() {
        var upload = file.files[0];
        previewPane.replaceChildren();
        if (!upload || upload.size > 4096) {
            notice.textContent = _('Выберите JSON-манифест размером до 4 КиБ');
            return;
        }
        inspect.disabled = true;
        upload.text().then(function(text) {
            return modulePreview(text).then(function(result) {
                if (file.files[0] !== upload) return;
                notice.textContent = result.error || '';
                if (result.error) return;
                var attach = E('button', { class: 'cbi-button cbi-button-apply', type: 'button' }, _('Подключить адаптер'));
                attach.addEventListener('click', function() {
                    store(moduleAttach(text), attach, _('Адаптер подключён'));
                });
                previewPane.replaceChildren(
                    E('h4', {}, result.name),
                    E('p', {}, [result.version, ' · ', E('code', {}, result.service),
                        result.category === 'vpn' || result.category === 'telegram-proxy' ?
                            ' · ' + templates.group(result.category).label : '']),
                    E('p', {}, result.description || ''),
                    attach
                );
            });
        }).catch(function() {
            notice.textContent = _('Не удалось проверить манифест');
        }).finally(function() { inspect.disabled = false; });
    });

    var content = E('div', {}, [
        E('div', { class: 'ows-module-heading' }, [E('h3', {}, _('Модули')), refresh]),
        list,
        E('details', { class: 'ows-overview ows-catalog-add' }, [
            E('summary', {}, _('Добавить решение')),
            E('h4', {}, _('Ссылка')),
            E('div', { class: 'ows-fields' }, [
                field('ows-link-name', _('Название'), name), field('ows-link-url', _('Источник HTTPS'), source)
            ]),
            E('div', { class: 'ows-actions' }, save),
            E('h4', {}, _('Манифест адаптера')),
            field('ows-manifest', _('Файл JSON'), file),
            E('div', { class: 'ows-actions' }, inspect),
            previewPane
        ]),
        notice
    ]);
    return { content: content, list: list, load: load };
}

return view.extend({
    load: function() {
        var localTemplates = templates.load();
        var services = session.getLocalData('menu')?.children?.admin?.children?.services?.children;
        if (!services?.zapret2?.satisfied) return localTemplates;

        return request.get(L.url('admin', 'menu'), { cache: false, timeout: 3000 }).then(function(response) {
            if (!response.ok) return;
            var current = response.json()?.children?.admin?.children?.services?.children;
            if (current?.ows?.satisfied && !current?.zapret2?.satisfied) {
                ui.menu.flushCache();
                if (!session.getLocalData('menu')) window.location.reload();
            }
        }).catch(function() {
            // The menu refresh must not prevent the OWS panel from opening.
        }).then(function() {
            return localTemplates;
        });
    },

    render: function(templateWarning) {
        var phase = E('p', { class: 'ows-phase', 'aria-live': 'polite' }, _('Загрузка статуса'));
        var job = E('code');
        var outputJob = '';
        var outputText = E('pre', { class: 'ows-job-output' });
        var details = E('details', { hidden: '' }, [E('summary', {}, _('Журнал задания')), outputText]);
        var selectedJob = '';
        var nextRefresh = 0;
        var jobObservers = Object.create(null);
        var moduleTemplates = Object.create(null);
        var services = serviceStatus.panel(function(error) {
            return statusLabel(error, moduleTemplates[error.kind]);
        }, jobOutput);
        function loadOutput() {
            var id = outputJob;
            if (!details.open || !id) return;
            outputText.textContent = _('Читаем журнал задания');
            return jobOutput(id).then(function(result) {
                if (id === outputJob) outputText.textContent = result.output || _('Журнал пуст');
            }, function() {
                if (id === outputJob) outputText.textContent = _('Не удалось прочитать журнал');
            });
        }
        details.addEventListener('toggle', loadOutput);

        function activePhase(phase) {
            return ['queued', 'waiting', 'validating', 'applying', 'rolling_back'].includes(phase);
        }

        function refresh(force) {
            var now = Date.now();
            if (!force && now < nextRefresh) return;
            var id = selectedJob;
            var request = id ? jobStatus(id) : status();
            function notify(result) {
                var observer = jobObservers[result.job];
                if (!observer || activePhase(result.phase)) return;
                delete jobObservers[result.job];
                observer(result);
                services.load();
            }
            var other = Object.keys(jobObservers).filter(function(key) { return key !== id; });
            nextRefresh = now + (other.length || jobObservers[id] ? 3000 : 15000);
            var primary = request.then(function(result) {
                notify(result);
                if (id !== selectedJob) return;
                if (activePhase(result.phase)) nextRefresh = Date.now() + 3000;
                phase.textContent = statusLabel(result, moduleTemplates[result.kind]);
                job.textContent = result.job || '';
                var nextOutput = result.has_output && result.phase !== 'applying' ? result.job : '';
                if (nextOutput !== outputJob) {
                    outputJob = nextOutput;
                    details.open = false;
                    details.hidden = !outputJob;
                    outputText.textContent = '';
                }
            }, function() {
                if (id !== selectedJob) return;
                phase.textContent = _('Не удалось получить статус OWS');
                job.textContent = '';
                details.hidden = true;
                outputJob = '';
            });
            return Promise.all([primary].concat(other.map(function(key) {
                return jobStatus(key).then(notify, function() {});
            })));
        }

        function followJob(id, observer) {
            selectedJob = id;
            if (observer) jobObservers[id] = observer;
            refresh(true);
        }

        var classicModule = zapret.init('zapret', followJob);
        var zapret2Module = zapret.init('zapret2', followJob, {
            revision: zapretTools.profileRevision,
            onNativeLoad: function() { refreshZapret2Tab('zapret2-presets'); },
            onApplied: onZapretConfigApplied
        });
        var classicHashes = {
            'zapret-service': '#ows-tab-zapret-service-panel',
            'zapret-native': '#ows-tab-zapret-native-panel'
        };
        var zapret2Hashes = {
            'zapret2-service': '#ows-tab-zapret2-service-panel',
            'zapret2-native': '#ows-tab-zapret2-native-panel',
            'zapret2-presets': '#ows-tab-zapret2-presets-panel'
        };
        var presetSectionHashes = {
            'zapret2-tactics': '#ows-tab-zapret2-tactics-panel',
            'zapret2-comparison': '#ows-tab-zapret2-comparison-panel',
            'zapret2-classification': '#ows-tab-zapret2-classification-panel',
            'zapret2-nfqueue': '#ows-tab-zapret2-nfqueue-panel',
            'zapret2-recovery': '#ows-tab-zapret2-recovery-panel'
        };
        var resourceAlias = '#ows-tab-zapret2-resources-panel';
        var showResources = window.location.hash === resourceAlias;
        var presetSection = showResources ? 'zapret2-tactics' : Object.keys(presetSectionHashes).find(function(id) {
            return presetSectionHashes[id] === window.location.hash;
        });
        var presetAliases = ['#ows-tab-zapret2-constructor-panel', resourceAlias].concat(Object.values(presetSectionHashes));
        var instructionsHash = '#ows-tab-instructions-panel';
        var classicStart = Object.keys(classicHashes).find(function(id) { return classicHashes[id] === window.location.hash; });
        var zapret2Start = presetAliases.includes(window.location.hash) ? 'zapret2-presets' :
            Object.keys(zapret2Hashes).find(function(id) { return zapret2Hashes[id] === window.location.hash; });
        var versionStart = zapret2Start || window.location.hash === '#ows-tab-zapret2-panel' ? 'zapret2' : 'zapret';
        var moduleHashes = Object.values(classicHashes).concat(Object.values(zapret2Hashes), presetAliases,
            ['#ows-tab-zapret-group-panel', '#ows-tab-zapret-panel', '#ows-tab-zapret2-panel']);
        var modules;

        function isZapretVersion(id) {
            return modules && modules.selectedId() === 'zapret-group' && zapretVersions.selectedId() === id;
        }

        function refreshZapret2Tab(id) {
            if (isZapretVersion('zapret2') && zapret2.selectedId() === id) zapret2.activate();
        }

        function onZapretConfigApplied() {
            refreshZapret2Tab('zapret2-native');
            if (isZapretVersion('zapret2') && zapret2.selectedId() === 'zapret2-presets' &&
                presetTab.selectedSection() === 'zapret2-tactics') tacticsTab.activate();
        }

        function rememberModuleTab(id, section) {
            var hash;
            if (id === 'instructions') hash = instructionsHash;
            if (id === 'zapret-group') {
                if (zapretVersions.selectedId() === 'zapret2') {
                    var tab = zapret2.selectedId();
                    hash = (tab === 'zapret2-presets' && presetSectionHashes[section || presetTab.selectedSection()]) || zapret2Hashes[tab];
                } else {
                    hash = classicHashes[classicTabs.selectedId()];
                }
            }
            if (hash === presetSectionHashes['zapret2-tactics'] && window.location.hash === resourceAlias) return;
            if (hash && window.location.hash !== hash)
                window.history.replaceState(window.history.state, '', hash);
            else if (!hash && (moduleHashes.includes(window.location.hash) || window.location.hash === instructionsHash))
                window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search);
        }

        var classicTabs = createTabs(_('Разделы Zapret'), [
            {id:'zapret-service',label:_('Служба и пакеты'),content:classicModule.status},
            classicModule.native
        ].map(function(tab) { return templates.panel(tab); }), classicStart, function() {
            if (isZapretVersion('zapret')) rememberModuleTab('zapret-group');
        });
        var tacticsTab = templates.panel(zapretTactics.tab(followJob, {
            showResources:showResources,
            panel:function(tab) { return templates.panel(tab); },
            onApplied:function() { refreshZapret2Tab('zapret2-native'); }
        }));
        var presetTab = templates.panel(zapretTools.presets(followJob,
            {content:zapret2Module.constructor, activate:zapret2Module.loadConstructor},
            onZapretConfigApplied, {
                panel:function(tab) { return templates.panel(tab); }, createTabs:createTabs, section:presetSection,tactics:tacticsTab,
                onSectionChange:function(id) {
                    if (isZapretVersion('zapret2') && zapret2.selectedId() === 'zapret2-presets')
                        rememberModuleTab('zapret-group', id);
                }
            }));
        var zapret2 = createTabs(_('Разделы Zapret2'), [
            { id: 'zapret2-service', label: _('Служба и пакеты'), content: zapret2Module.status },
            zapret2Module.native
        ].map(function(tab) { return templates.panel(tab); }).concat(presetTab), zapret2Start, function() {
            if (isZapretVersion('zapret2')) rememberModuleTab('zapret-group');
        });
        var zapretVersions = createTabs(_('Версии Zapret'), [
            { id:'zapret', label:_('Версия 1'), content:[classicTabs.content, classicModule.feedback],
                activate:function() {
                    if (!zapretVersions) return;
                    classicModule.refresh();
                    classicTabs.activate();
                } },
            { id:'zapret2', label:_('Версия 2'), content:[zapret2.content, zapret2Module.feedback],
                activate:function() {
                    if (!zapretVersions) return;
                    zapret2Module.refresh();
                    zapret2.activate();
                } }
        ].map(function(tab) { return templates.panel(tab); }), versionStart, function() {
            if (modules && modules.selectedId() === 'zapret-group') rememberModuleTab('zapret-group');
        });

        function selectZapretVersion(id, tab) {
            var sections = id === 'zapret2' ? zapret2 : classicTabs;
            return sections.selectId(tab) && zapretVersions.selectId(id);
        }
        var workspace = E('div');
        var instructionsTab = templates.panel(instructions.tab());
        var registry = adapterCatalog(renderModules);
        var installing = Object.create(null);
        var linkReport = E('ul', {'aria-live':'polite'});
        var linkCheck = E('button', {type:'button',class:'cbi-button'}, _('Проверить ссылки модулей'));
        linkCheck.addEventListener('click', function() {
            linkCheck.disabled = true;
            moduleLinks().then(function(data) {
                var labels = {
                    ready:_('Доступен'), not_installed:_('Не установлен'), engine_only:_('Управляется из OWS'),
                    invalid_route:_('Неверный маршрут LuCI'), missing_view:_('Отсутствует файл интерфейса'),
                    awaiting_configuration:_('Ожидает применения манифеста'),
                    configuration_unavailable:_('Рабочая конфигурация недоступна'), broken_references:_('Есть отсутствующие файлы'),
                    invalid_manifest:_('Запись каталога повреждена'), invalid_source:_('Некорректная HTTPS-ссылка'),
                    source_valid:_('Формат HTTPS-ссылки корректен')
                };
                linkReport.replaceChildren.apply(linkReport, data.modules.map(function(item) {
                    return E('li', {}, (item.label || item.module) + ' · ' + (labels[item.status] || item.status) +
                        (item.missing > 0 ? ' (' + item.missing + ')' : ''));
                }));
            }).catch(function() {
                linkReport.replaceChildren(E('li', {}, _('Не удалось проверить ссылки модулей.')));
            }).finally(function() { linkCheck.disabled = false; });
        });

        function installButton(entry) {
            var button = E('button', {class:'cbi-button',type:'button'},
                entry.needs_interface ? _('Установить интерфейс LuCI') : _('Установить'));
            button.disabled = !!installing[entry.id];
            button.addEventListener('click', function() {
                if (installing[entry.id] || !window.confirm(entry.installConfirmation ||
                    _('Установить %s и необходимые пакеты?').format(entry.name))) return;
                installing[entry.id] = true;
                button.disabled = true;
                moduleInstall(entry.id).then(function(result) {
                    if (!result || !result.job) throw new Error(result && result.error || _('Установка недоступна'));
                    followJob(result.job, function() {
                        delete installing[entry.id];
                        registry.load();
                    });
                }).catch(function(error) {
                    delete installing[entry.id];
                    button.disabled = false;
                    ui.addNotification(null, E('p', {}, error.message), 'error');
                });
            });
            return button;
        }

        var cleanupPanel = templates.panel({id:'legacy-cleanup', content:legacyCleanup.panel(followJob)});
        var uninstallPanel = E('details', {class:'ows-section'}, [
            E('summary', {}, _('Удаление OWS и модулей')),
            E('p', {}, _('Выполните команды по SSH. Первая покажет план. Вторая удалит OWS и установленные встроенные модули.')),
            E('pre', {}, 'ows-uninstall --check --all-modules\nows-uninstall --apply --all-modules')
        ]);
        var systemTabs = createTabs(_('Системные модули'), templates.system(followJob));
        var systemPanel = templates.panel({id:'overview-system',content:E('section', {class:'ows-service-preview'}, [
            E('h4', {}, _('Системные модули')), systemTabs.content
        ]),activate:systemTabs.activate});
        var domainTargets;
        var domainPanel = domainSearch.panel(function(match) {
            var open = domainTargets[match.module];
            return open ? open(match) : false;
        });
        var selectedGroup = Object.create(null);

        function renderModules(entries, vpnDrivers, installed) {
            moduleTemplates = Object.create(null);
            domainTargets = Object.create(null);
            domainTargets.zapret2 = function() {
                return selectZapretVersion('zapret2', zapret2Module.native.id) && modules.selectId('zapret-group');
            };
            var tabs = [
                { id: 'overview', label: _('Обзор'), activate:systemPanel.activate,
                    content: [templates.panel({id:'domain-search', content:domainPanel}).content, registry.content,
                        E('div', {class:'ows-overview'}, [linkCheck, linkReport]), cleanupPanel.content, uninstallPanel] },
                { id: 'zapret-group', label: _('Zapret'), content: zapretVersions.content, activate: zapretVersions.activate }
            ].map(function(tab) { return templates.panel(tab); });
            tabs.push(instructionsTab);
            var rows = [
                {id:'zapret2',name:'Zapret2',description:_('Движок nfqws2, редактор тактик и конструктор'),tab:1,installed:installed.zapret2,installable:installed.zapret2 === false,
                    open:function() { selectZapretVersion('zapret2', 'zapret2-service'); }},
                {id:'zapret',name:'Zapret',description:_('Первая версия, движок nfqws'),tab:1,installed:installed.zapret,installable:installed.zapret === false,
                    open:function() { selectZapretVersion('zapret', 'zapret-service'); }},
                {content:systemPanel.content}
            ];
            var groups = Object.create(null);
            var context = { createTabs: createTabs, followJob: followJob };

            ['vpn', 'telegram-proxy'].forEach(function(id) {
                var group = templates.group(id);
                var content = E('div');
                var children = [];
                var nested;

                function open(index) {
                    if (nested) {
                        if (index != null) nested.select(index);
                        return;
                    }
                    if (!children.length) {
                        content.replaceChildren(E('p', {}, group.empty));
                        return;
                    }
                    nested = createTabs(group.sectionsLabel, children, index == null ? selectedGroup[id] : index,
                        function(tabId) { selectedGroup[id] = tabId; });
                    content.replaceChildren(nested.content);
                }

                groups[id] = { index: tabs.length, tabs: children, open: open };
                tabs.push({ id: id, label: group.label, content: content, activate: open });
            });
            tabs.push(templates.panel(dns.tab(followJob)));
            rows.push({id:'doh',name:'DoH',description:_('DNS через HTTPS'),tab:tabs.length,
                installed:installed.doh,installable:installed.doh === false,
                installConfirmation:_('Установить HTTPS DNS Proxy из репозитория OpenWrt? Пакет может запустить службу и изменить DNS.')});
            tabs.push(templates.panel(doh.tab(followJob)));
            entries.forEach(function(entry) {
                if (entry.id === 'zapret' || entry.id === 'zapret2') return;
                if (entry.kind !== 'adapter') {
                    rows.push(entry);
                    return;
                }
                var template = templates.resolve(entry, vpnDrivers);
                moduleTemplates[entry.id] = template;
                entry = Object.assign({}, entry, {
                    name: template.label || entry.name,
                    sourceLabel: template.sourceLabel,
                    installable: !!template.install && (entry.installed === false || entry.needs_interface),
                    installConfirmation: template.installConfirmation
                });
                var tab = (template.tab && template.tab(entry, context, template)) || adapterTab(entry);
                var source = entrySource(entry, entry.sourceLabel);
                var actions = [];
                if (entry.installable && template.installInTab) actions.push(installButton(entry));
                if (source && entry.sourceLabel) actions.push(source);
                if (actions.length) tab.content = [E('div', {class:'ows-actions'}, actions)].concat(tab.content);
                tab = templates.panel(tab);
                var group = groups[template.group];
                var top = group ? group.index : tabs.length;
                var index = group ? group.tabs.length : null;
                if (entry.id === 'steer' || entry.id === 'adblock-fast') {
                    var target = entry.id === 'steer' ? 'steer' : 'adblock';
                    domainTargets[target] = function(match) {
                        if (group) group.open(index);
                        modules.select(top);
                        if (tab.openSection) tab.openSection(target === 'steer' ? 'services' : match.list);
                        return true;
                    };
                }
                if (group) {
                    rows.push(Object.assign({ tab: group.index, open: function() { group.open(index); } }, entry));
                    group.tabs.push(tab);
                } else {
                    rows.push(Object.assign({ tab: tabs.length }, entry));
                    tabs.push(tab);
                }
            });
            registry.list.replaceChildren.apply(registry.list, rows.map(function(entry) {
                if (entry.content) return entry.content;
                var actions = [];
                if (entry.installable) actions.push(installButton(entry));
                if (entry.tab != null) {
                    var open = E('button', { class: 'cbi-button', type: 'button' }, _('Открыть'));
                    open.addEventListener('click', function() {
                        if (entry.open) entry.open();
                        modules.select(entry.tab);
                    });
                    actions.push(open);
                }
                var link = entrySource(entry, entry.sourceLabel);
                if (link) actions.push(link);
                return E('section', { class: 'ows-overview' }, [
                    E('div', {}, [
                        E('h4', {}, entry.name),
                        E('p', {}, entry.kind === 'link' ? _('Сохранённая ссылка') :
                            (entry.description || '') + (entry.installed === false ? ' · ' + _('Пакет не установлен') : ''))
                    ]),
                    E('div', { class: 'ows-actions ows-entry-actions' }, actions)
                ]);
            }));
            var initial = window.location.hash === instructionsHash ? 'instructions' :
                moduleHashes.includes(window.location.hash) ? 'zapret-group' : 'overview';
            var active = modules ? modules.selectedId() : initial;
            modules = createTabs(_('Модули OWS'), tabs, active, rememberModuleTab);
            workspace.replaceChildren(modules.content);
        }

        renderModules([], {}, {});
        registry.load();
        refresh();
        services.load();
        poll.add(function() { return refresh(false); }, 3);
        poll.add(services.load, 60);
        return E('div', { class: 'ows' }, [
            E('link', { rel: 'stylesheet', href: L.resource('view/ows-services.css') }),
            E('h2', {}, _('OWS')),
            templateWarning ? E('p', { role: 'status' }, templateWarning) : '',
            E('section', { class: 'ows-status', 'aria-label': _('Очередь OWS') }, [
                E('strong', {}, _('Последняя операция')),
                phase,
                job,
                details,
                services.content
            ]),
            workspace
        ]);
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null
});
