function activateTabs() {
    $('#inst_show_tabs li:first').addClass('active');
    $('div.tab-content div.tab-pane:first').addClass('active');
    $('#alert_index_tabs li:first').addClass('active');
}

function dropdown() {
    $('.dropdown-toggle').dropdown();
}

function pass_popover() {
    $('[data-toggle="password_popover"]').popover({html:true});
}

function addClickFunctions() {
    var buttons = $("a.btn-sm.btn-default");
    for (var i = 0; i < buttons.length; i++) {
        buttons[i].onclick = makeButtonClickFunction(buttons[i]);
    }
}

function makeButtonClickFunction(button) {
    return function () {
        var href = $(button).attr("href");
        window.location.assign(href);
    };
}

function tabbed_nav(controller) {
    var controllerSwitch = {
        "institutions": function () { activateNavTab('inst_tab'); },
        "intellectual_objects": function () { activateNavTab('io_tab'); },
        "generic_files": function () { activateNavTab('gf_tab'); },
        "work_items": function () { activateNavTab('wi_tab'); },
        "premis_events": function () { activateNavTab('pe_tab'); },
        "dpn_work_items": function () { activateNavTab('dpn_tab'); },
        "reports": function () { activateNavTab('rep_tab'); },
        "alerts": function () { activateNavTab('alert_tab'); },
        "dpn_bags": function () { activateNavTab('dpn_bag_tab'); },
        "catalog": function () {},
        "devise/password_expired": function () {},
        "users": function () {}
    };
    controllerSwitch[controller]();
}

function report_nav(type) {
    var reportTypeSwitch = {
        "general": function () { activateNavTab('general_tab'); },
        "subscriber": function () { activateNavTab('subscribers_tab'); },
        "cost": function () { activateNavTab('cost_tab'); },
        "timeline": function () { activateNavTab('timeline_tab'); },
        "mimetype": function () { activateNavTab('mimetype_tab'); },
        "breakdown": function () { activateNavTab('breakdown_tab'); }
    };
    reportTypeSwitch[type]();
}

function activateNavTab(id) {
    $('#'+id).addClass('active');
}

function autofillUserCreateForm() {
    var pass = document.getElementById("user_password");
    pass.value = "passwordabc";
    $("label[for='user_password']").addClass("hidden");
    //pass.classList.add("hidden");
    var passCon = document.getElementById("user_password_confirmation");
    passCon.value = "passwordabc";
    $("label[for='user_password_confirmation']").addClass("hidden");
    //passCon.classList.add("hidden");
}

$(document).ready(function(){
    fixFilters();
    activateTabs();
    dropdown();
    fixSearchBreadcrumb();
    addClickFunctions();
    pass_popover();
    autofillUserCreateForm();
});