'use strict';
'require view';
'require view.zapret2.loader as native';

var registrationWrapped = false;

function omitSection(module, method, type) {
    return L.require(module).then(function(view) {
        var register = view[method];
        if (typeof register !== 'function') return;
        view[method] = function(map) {
            var result = register.call(this, map);
            var index = map.children.findIndex(function(section) { return section.sectiontype === type; });
            if (index >= 0) map.children.splice(index, 1);
            return result;
        };
    }, function() {});
}

return view.extend({
    load: function() {
        return native.load().then(function(data) {
            if (registrationWrapped) return data;
            // Use the module instance already loaded by the native versioned loader.
            return Promise.all([
                omitSection('view.zapret2.strategy-compare', 'createCompareTab', '_strategy_compare_tab'),
                omitSection('view.zapret2.strategy-guide', 'createGuideTab', '_zapret2_guide_tab')
            ]).then(function() {
                registrationWrapped = true;
                return data;
            });
        });
    },

    render: function(data) { return native.render(data); },
    addFooter: function() { return native.addFooter(); }
});
