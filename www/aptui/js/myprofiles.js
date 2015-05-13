require(window.APT_OPTIONS.configObject,
	['js/quickvm_sup', 'moment',
	 'tablesorter', 'tablesorterwidgets'],
function (sup, moment)
{
    'use strict';
    var ajaxurl = null;

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);
	ajaxurl  = window.AJAXURL;

	var table = $(".tablesorter")
		.tablesorter({
		    theme : 'green',
		    
		    //cssChildRow: "tablesorter-childRow",

		    // initialize zebra and filter widgets
		    widgets: ["zebra", "filter", "resizable"],

		    widgetOptions: {
			// include child row content while filtering, if true
			filter_childRows  : true,
			// include all columns in the search.
			filter_anyMatch   : true,
			// class name applied to filter row and each input
			filter_cssFilter  : 'form-control',
			// search from beginning
			filter_startsWith : false,
			// Set this option to false for case sensitive search
			filter_ignoreCase : true,
			// Only one search box.
			filter_columnFilters : false,
		    },

		    headers: { 1: { sorter: false}, 2: {sorter: false} }
		});

	// Target the $('.search') input using built in functioning
	// this binds to the search using "search" and "keyup"
	// Allows using filter_liveSearch or delayed search &
	// pressing escape to cancel the search
	$.tablesorter.filter.bindSearch( table, $('#profile_search') );

	$('.showtopo_modal_button').click(function (event) {
	    event.preventDefault();
	    ShowTopology($(this).data("profile"));
	});
	
	// Format dates with moment before display.
	$('.format-date').each(function() {
	    var date = $.trim($(this).html());
	    if (date != "") {
		$(this).html(moment($(this).html()).format("ll"));
	    }
	});
    }

    function ShowTopology(profile)
    {
	var profile;
	var index;
    
	var callback = function(json) {
	    if (json.code) {
		alert("Failed to get rspec for topology viewer: " + json.value);
		return;
	    }
	    sup.ShowModal("#quickvm_topomodal");
	    $("#quickvm_topomodal").one("shown.bs.modal", function () {
		sup.maketopmap('#showtopo_nopicker', json.value.rspec, null);
	    });
	};
	var $xmlthing = sup.CallServerMethod(ajaxurl,
					     "myprofiles",
					     "GetProfile",
				     	     {"uuid" : profile});
	$xmlthing.done(callback);
    }

    $(document).ready(initialize);
});
