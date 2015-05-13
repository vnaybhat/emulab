require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup',
	 'js/lib/text!template/create-dataset.html',
	 'jquery-ui'],
function (_, sup, mainString)
{
    'use strict';

    var mainTemplate = _.template(mainString);
    var fields       = null;
    var fstypes      = null;
    var projlist     = null;
    
    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);

	fields   = JSON.parse(_.unescape($('#form-json')[0].textContent));
	fstypes  = JSON.parse(_.unescape($('#fstypes-json')[0].textContent));
	// Project list is optional on this page.
	if ($('#projects-json').length) {
	    projlist = JSON.parse(_.unescape($('#projects-json')[0].textContent));
	}
	
	GeneratePageBody(fields, null);
    }

    //
    // Moved into a separate function since we want to regen the form
    // after each submit, which happens via ajax on this page. 
    //
    function GeneratePageBody(formfields, errors)
    {
	// Generate the template.
	var html = mainTemplate({
	    formfields:		formfields,
	    fstypes:		fstypes,
	    projects:           projlist,
	    title:		window.TITLE,
	    embedded:		window.EMBEDDED,
	});
	html = formatter(html, errors).html();
	$('#main-body').html(html);

	// Insert datepicker after html inserted.
	$(function() {
	    $("#dataset_expires").datepicker({
		showButtonPanel: true,
		dateFormat: "yy-mm-dd"
	    });
	});

	// stdatasets need the datepicker.
	$('#create_dataset_form input[type=radio]').change(function() {
	    var val = $(this).val();
	    if (val == "ltdataset") {
		$('#dataset_expires_div').addClass("hidden");
	    }
	    else {
		$('#dataset_expires_div').removeClass("hidden");
	    }
	});

	//
	// Handle submit button.
	//
	$('#dataset_submit_button').click(function (event) {
	    event.preventDefault();
	    HandleSubmit();
	});
    }
    
    // Formatter for the form. This did not work out nicely at all!
    function formatter(fieldString, errors)
    {
	var root   = $(fieldString);
	var list   = root.find('.format-me');
	list.each(function (index, item) {
	    if (item.dataset) {
		var key     = item.dataset['key'];
		var margin  = 15;
		var colsize = 12;

		var outerdiv = $("<div class='form-group' " +
				 "     style='margin-bottom: " + margin +
				 "px;'></div>");

		if ($(item).attr('data-label')) {
		    var label_text =
			"<label for='" + key + "' " +
			" class='col-sm-3 control-label'> " +
			item.dataset['label'];
		    
		    if ($(item).attr('data-help')) {
			label_text = label_text +
			    "<a href='#' class='btn btn-xs' " +
			    " data-toggle='popover' " +
			    " data-html='true' " +
			    " data-delay='{\"hide\":1000}' " +
			    " data-content='" + item.dataset['help'] + "'>" +
			    "<span class='glyphicon glyphicon-question-sign'>" +
			    " </span></a>";
		    }
		    label_text = label_text + "</label>";
		    outerdiv.append($(label_text));
		    colsize = 6;
		}
		var innerdiv = $("<div class='col-sm-" + colsize + "'></div>");
		innerdiv.html($(item).clone());
		
		if (errors && _.has(errors, key)) {
		    outerdiv.addClass('has-error');
		    innerdiv.append('<label class="control-label" ' +
				    'for="inputError">' +
				    _.escape(errors[key]) + '</label>');
		}
		outerdiv.append(innerdiv);
		$(item).after(outerdiv);
		$(item).remove();
	    }
	});
	return root;
    }

    function HandleSubmit()
    {
	// Submit with check only at first, since this will return
	// very fast, so no need to throw up a waitwait.
	SubmitForm(1);
    }

    //
    // Submit the form.
    //
    function SubmitForm(checkonly)
    {
	// Current form contents as formfields array.
	var formfields  = {};
	
	var callback = function(json) {
	    console.info(json);
	    if (!checkonly) {
		sup.HideModal("#waitwait");
	    }
	    if (json.code) {
		if (checkonly && json.code == 2) {
		    // Regenerate page with errors.
		    GeneratePageBody(formfields, json.value);
		    return;
		}
		sup.SpitOops("oops", json.value);
		return;
	    }
	    // Now do the actual create.
	    if (checkonly) {
		sup.ShowModal("#waitwait");
		SubmitForm(0);
	    }
	    else {
		// Create succeeded.
		window.location.replace(json.value);
	    }
	}
	// Convert form data into formfields array, like all our
	// form handler pages expect.
	var fields = $('#create_dataset_form').serializeArray();
	$.each(fields, function(i, field) {
	    formfields[field.name] = field.value;
	});
	// This clears any errors before new submit. Needs more thought.
	GeneratePageBody(formfields, null);

	var xmlthing = sup.CallServerMethod(null, "dataset", "create",
					    {"formfields" : formfields,
					     "checkonly"  : checkonly});
	xmlthing.done(callback);
    }

    $(document).ready(initialize);
});


