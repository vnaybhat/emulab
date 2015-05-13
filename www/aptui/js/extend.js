//
// Progress Modal
//
define(['underscore', 'js/quickvm_sup',
	'js/lib/text!template/user-extend-modal.html',
	'js/lib/text!template/admin-extend-modal.html',
	'js/lib/text!template/guest-extend-modal.html'],
	
    function(_, sup, userExtendString, adminExtendString, guestExtendString)
    {
	'use strict';
	var modalname  = '#extend_modal';
	var divname    = '#extend_div';
	var slidername = "#extend_slider";
	var isadmin    = 0;
	var isguest    = 0;
	var uuid       = 0;
	var callback   = null;
	var howlong    = 1; // Number of days being requested.

	function Initialize()
	{
	    howlong  = 1;
	    
	    // Click handler.
	    $('button#request-extension').click(function (event) {
		event.preventDefault();
		RequestExtension();
	    });

	    /*
	     * If the modal contains the slider, set it up.
	     */
	    if ($(slidername).length) {
		InitializeSlider();
	    }

	    /*
	     * Callback to format check the date box.
	     */
	    if ($('#datepicker').length) {
		$('#datepicker').off("change");
		$('#datepicker').change(function() {
		    // regular expression to match required date format
		    var re  = /^\d{1,2}\/\d{1,2}\/\d{4}$/;
		    var val = $('#datepicker').val();

		    if (! val.match(re)) {
			alert("Invalid date format: " + val);
			// This does not work.
			$("#datepicker").focus();
			return false;
		    }
		});
	    }
	    
	    /*
	     * Countdown for text box.
	     */
	    $('#why_extend').on('focus keyup', function (e) {
		UpdateCountdown();
	    });
	    // Clear existing text.
	    $('#why_extend').val('');
	}

	function InitializeSlider()
	{
	    var labels = [];
	    
	    labels[0] = "1 day";
	    labels[1] = "7 days";
	    labels[2] = "4 weeks";
	    labels[3] = "Longer";

	    $(slidername).slider({value:0,
			   max: 100,
			   slide: function(event, ui) {
			       SliderChanged(ui.value);
			   },
			   start: function(event, ui) {
			       SliderChanged(ui.value);
			   },
			   stop: function(event, ui) {
			       SliderStopped(ui.value);
			   },
			  });

	    // how far apart each option label should appear
	    var width = $(slidername).width() / (labels.length - 1);

	    // Put together the style for <p> tags.
	    var left  = "style='width: " + width/2 +
		"px; display: inline-block; text-align: left;'";
	    var mid   = "style='width: " + width +
		"px; display: inline-block; text-align: center;'";
	    var right = "style='width: " + width/2 +
		"px; display: inline-block; text-align: right;'";

	    // Left most label.
	    var html = "<p " + left + ">" + labels[0] + "</p>";

	    // Middle labels.
	    for (var i = 1; i < labels.length - 1; i++) {
		html = html + "<p " + mid + ">" + labels[i] + "</p>";
	    }

	    // Right most label.
	    html = html + "<p " + right + ">" + labels[labels.length-1] + "</p>";

	    // Overwrite existing legend if we already displayed the modal.
	    if ($('#extend_slider_legend').length) {
		$('#extend_slider_legend').html(html);
	    }
	    else {
		// The entire legend;
		html =
		    '<div id="extend_slider_legend" class="ui-slider-legend">' +
		    html + '</div>';
 
		// after the slider create a containing div with the p tags.
		$(slidername).after(html);
	    }
	}

	/*
	 * User has changed the slider. Show new instructions.
	 */
	var minchars  = 120; // For the character countdown.
	var lastvalue = 0;   // Last callback value.
	var lastlabel = 0;   // So we know which div to hide.
	var setvalue  = 0;   // where to jump the slider to after stop.
	function SliderChanged(which) {
	    var slider   = $(slidername);
	    var label    = 0;

	    if (lastvalue == which) {
		return;
	    }

	    /*
	     * This is hack to achive a non-linear slider. 
	     */
	    var extend_value = "1 day";
	    if (which <= 33) {
		var divider  = 33 / 6.0;
		var day      = Math.round(which / divider) + 1;
		extend_value = day + " days";
		setvalue     = Math.round((day - 1) * divider);
		label        = 0;
		howlong      = day;
	    }
	    else if (which <= 66) {
		var divider  = 33 / 20.0;
		var day      = Math.round((which - 33) / divider) + 7;
		extend_value = day + " days";
		setvalue     = Math.round((day - 7) * divider) + 33;
		label        = 1;
		howlong      = day;
	    }
	    else if (which <= 97) {
		var divider  = 33 / 8.0;
		var week     = Math.round((which - 66) / divider) + 4;
		extend_value = week + " weeks";
		setvalue     = Math.round((week - 4) * divider) + 66;
		label        = 2;
		howlong      = week * 7;
	    }
	    else {
		extend_value = "Longer";
		setvalue     = 100;
		label        = 3;
		// User has to fill in the date box, then we can figure
		// it out. 
		howlong      = null;
	    }
	    $('#extend_value').html(extend_value);

	    $('#label' + lastlabel + "_request").addClass("hidden");
	    $('#label' + label + "_request").removeClass("hidden");

	    // For the char countdown below.
	    minchars = $('#label' + label + "_request").attr('data-minchars');
	    UpdateCountdown();

	    lastvalue = which;
	    lastlabel = label;
	}

	// Jump to closest stop when user finishes moving.
	function SliderStopped(which) {
	    $(slidername).slider("value", setvalue);
	}

	function UpdateCountdown() {
	    var len   = $('#why_extend').val().length;
	    var msg   = "";

	    if (len) {
		var left  = minchars - len;
		if (left <= 0) {
		    left = 0;
		    EnableSubmitButton();
		}
		else if (left) {
		    msg = "You need at least " + left + " more characters";
		    DisableSubmitButton();
		}
	    }
	    else {
		DisableSubmitButton();
	    }
	    $('#extend_counter_msg').html(msg);
	}

	//
	// Request experiment extension. 
	//
	function RequestExtension()
	{
	    var reason  = "";

	    if (isadmin) {
		howlong = $("#howlong_extend").val();
	    }
	    else {
		if (howlong == null) {
		    /*
		     * The value comes from the datepicker.
		     */
		    if ($('#datepicker').val() == "") {
			alert("You have to specify a date!");
			$("#datepicker").focus();
			return;
		    }
		    /*
		     * Convert date to howlong in days.
		     */
		    var today = new Date();
		    var later = new Date($('#datepicker').val());
		    var diff  = (later - today);
		    if (diff < 0) {
			alert("No time travel to the past please");
			$("#datepicker").focus();
			return;
		    }
		    howlong = parseInt((diff / 1000) / (3600 * 24));
		    if (howlong < 1)
			howlong = 1;
		}
		reason = $("#why_extend").val();
		if (reason.length < minchars) {
		    alert("Your reason is too short! Say more please.");
		    return;
		}
	    }
	    sup.HideModal('#extend_modal');
	    sup.ShowModal("#waitwait-modal");
	    var xmlthing = sup.CallServerMethod(null,
						"status",
						"RequestExtension",
						{"uuid"   : uuid,
						 "howlong": howlong,
						 "reason" : reason});
	    xmlthing.done(function(json) {
		sup.HideModal("#waitwait-modal");
		console.info(json.value);
		callback(json);
		return;
	    });
	}

	function EnableSubmitButton()
	{
	    ButtonState('button#request-extension', 1);
	}
	function DisableSubmitButton()
	{
	    ButtonState('button#request-extension', 0);
	}
	function ButtonState(button, enable)
	{
	    if (enable) {
		$(button).removeAttr("disabled");
	    }
	    else {
		$(button).attr("disabled", "disabled");
	    }
	}
	return function(thisuuid, func, admin, guest, extendfor)
	{
	    isadmin  = admin;
	    isguest  = guest;
	    uuid     = thisuuid;
	    callback = func;
	    
	    $('#extend_div').html(isadmin ?
				  adminExtendString : isguest ?
				  guestExtendString : userExtendString);

	    // We have to wait till it is shown to actually set up
	    // some of the content, since we need to know its width.
	    $(modalname).on('shown.bs.modal', function (e) {
		Initialize();
		if (extendfor && isadmin) {
		    $("#howlong_extend").val(extendfor);
		}
		$(modalname).off('shown.bs.modal');
	    });
	    $(modalname).modal('show');
	}
    }
);
