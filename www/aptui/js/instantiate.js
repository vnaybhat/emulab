require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup', // jQuery modules
	 'js/lib/text!template/aboutapt.html',
	 'js/lib/text!template/aboutcloudlab.html',
         'formhelpers', 'filestyle', 'marked'],
function (_, sup, aboutaptString, aboutcloudString)
{
    'use strict';

    var ajaxurl;

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);
	ajaxurl = window.AJAXURL;

	// The about panel.
	if (window.SHOWABOUT) {
	    $('#about_div').html(window.ISCLOUD ?
				 aboutcloudString : aboutaptString);
	}

	if (window.APT_OPTIONS.isNewUser) {
	    $('#verify_modal_submit').click(function (event) {
		$('#verify_modal').modal('hide');
		$("#waitwait").modal('show');
		return true;
	    });
	    $('#verify_modal').modal('show');
	}
        $('#quickvm_topomodal').on('shown.bs.modal', function() {
            ShowProfileList($('.current'))
        });

	$('button#reset-form').click(function (event) {
	    event.preventDefault();
	    resetForm($('#quickvm_form'));
	});
	$('button#profile').click(function (event) {
	    event.preventDefault();
	    $('#quickvm_topomodal').modal('show');
	});
	$('li.profile-item').click(function (event) {
	    event.preventDefault();
	    ShowProfileList(event.target);
	});
	$('button#showtopo_select').click(function (event) {
	    event.preventDefault();
	    UpdateProfileSelection($('.selected'));
	    ShowProfileList($('.selected'));
	    $('#quickvm_topomodal').modal('hide');
	});
	$('#instantiate_submit').click(function (event) {
	    $("#waitwait").modal('show');
	    return true;
	});
	var startProfile = $('#profile_name li[value = ' + window.PROFILE + ']')
        UpdateProfileSelection(startProfile);
	ShowProfileList(startProfile, true);
	_.delay(function () {$('.dropdown-toggle').dropdown();}, 500);
    }

    function resetForm($form) {
	$form.find('input:text, input:password, select, textarea').val('');
    }
    
    function UpdateProfileSelection(selectedElement)
    {
	var profile_name = $(selectedElement).text();
	var profile_value = $(selectedElement).attr('value');
	$('#selected_profile').attr('value', profile_value);
	$('#selected_profile_text').html("" + profile_name);

	if (!$(selectedElement).hasClass('current')) {
	    $('#profile_name li').each(function() {
		$(this).removeClass('current');
	    });
	    $(selectedElement).addClass('current');
	}
    }

    function ShowProfileList(selectedElement, justTitle)
    {
	var profile = $(selectedElement).attr('value');

	if (!$(selectedElement).hasClass('selected')) {
	    $('#profile_name li').each(function() {
		$(this).removeClass('selected');
	    });
	    $(selectedElement).addClass('selected');
	}

	var callback = function(json) {
	    if (json.code) {
		alert("Could not get profile: " + json.value);
		return;
	    }
	    
	    var xmlDoc = $.parseXML(json.value.rspec);
	    var xml    = $(xmlDoc);
    
	    $('#showtopo_title').html("<h3>" + json.value.name + "</h3>");

	    /*
	     * We now use the desciption from inside the rspec, unless there
	     * is none, in which case look to see if the we got one in the
	     * rpc reply, which we will until all profiles converted over to
	     * new format rspecs.
	     */
	    var description = null;
	    $(xml).find("rspec_tour").each(function() {
		$(this).find("description").each(function() {
		    var marked = require("marked");
		    description = marked($(this).text());
		});
	    });
	    if (!description || description == "") {
		description = "Hmm, no description for this profile";
	    }
	    $('#showtopo_description').html(description);
	    $('#selected_profile_description').html(description);

	    if (! justTitle) {
		sup.maketopmap('#showtopo_div', json.value.rspec, null);
	    }
	}
	var $xmlthing = sup.CallServerMethod(ajaxurl,
					     "instantiate", "GetProfile",
					     {"uuid" : profile});
	$xmlthing.done(callback);
    }

    $(document).ready(initialize);
});
