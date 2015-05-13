require(window.APT_OPTIONS.configObject,
	['js/quickvm_sup',
	 'tablesorter', 'tablesorterwidgets'],
function (sup)
{
    'use strict';
    var ajaxurl = null;

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);
	ajaxurl  = window.AJAXURL;

	if ($(".tablesorter").length) {
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
	    $.tablesorter.filter.bindSearch( table, $('#dataset_search') );
	}
	// Format dates with moment before display.
	$('.format-date').each(function() {
	    var date = $.trim($(this).html());
	    if (date != "") {
		$(this).html(moment($(this).html()).format("lll"));
	    }
	});

	//
	// When embedded, we want the Show link to go through the outer
	// frame not the inner iframe.
	//
	if (window.EMBEDDED) {
	    $('*[id*=show-dataset-button]').click(function (event) {
		event.preventDefault();
		var url = $(this).attr("href");
		console.info(url);
		window.parent.location.replace("../" + url);
		return false;
	    });
	    $('*[id*=embedded-anchors]').click(function (event) {
		event.preventDefault();
		var url = $(this).attr("href");
		console.info(url);
		window.parent.location.replace("../" + url);
		return false;
	    });
	}
    }

    $(document).ready(initialize);
});
