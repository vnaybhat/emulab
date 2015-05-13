require(window.APT_OPTIONS.configObject,
	['underscore', 'js/quickvm_sup',
	 'js/lib/text!template/about-account.html',
	 'js/lib/text!template/verify-modal.html',
	 'js/lib/text!template/signup-personal.html',
	 'js/lib/text!template/signup-project.html',
	 'js/lib/text!template/signup.html',
	 // jQuery modules
	 'formhelpers'],
function (_, sup,
	  aboutString, verifyString, personalString,
	  projectString, signupString)
{
    'use strict';

    var aboutTemplate = _.template(aboutString);
    var verifyTemplate = _.template(verifyString);
    var personalTemplate = _.template(personalString);
    var projectTemplate = _.template(projectString);
    var signupTemplate = _.template(signupString);
    var ISCLOUD = 0;

    function initialize()
    {
	window.APT_OPTIONS.initialize(sup);
	ISCLOUD = window.ISCLOUD;

	var fields = JSON.parse(_.unescape($('#form-json')[0].textContent));
	var errors = JSON.parse(_.unescape($('#error-json')[0].textContent));
	renderForm(fields, errors,
		   window.APT_OPTIONS.joinproject,
		   window.APT_OPTIONS.ShowVerifyModal,
		   window.APT_OPTIONS.this_user);

	/*
	 * When switching from start to join, show the hidden fields
	 * and change the button.
	 */
	$("input[id='startorjoin']").change(function(e){
	    if ($(this).val() == "join") {
		$('#start_project_rollup').addClass("hidden");
		$('#submit_button').text("Join Project");
		$('#signup_panel_title').text("Join Project");
	    }
	    else {
		$('#start_project_rollup').removeClass("hidden");
		$('#submit_button').text("Start Project");
		$('#signup_panel_title').text("Start Project");
	    }
	});
    }

    function renderForm(formfields, errors, joinproject, showVerify, thisUser)
    {
	var buttonLabel = (joinproject ? "Join Project" : "Start Project");
	var about = aboutTemplate({});
	var verify = verifyTemplate({
	    id: 'verify_modal',
	    label: buttonLabel
	});
	var personal = formatter(personalTemplate({
	    formfields: formfields
	}), errors);
	var project = Newformatter(projectTemplate({
	    joinproject: joinproject,
	    formfields: formfields
	}), errors);
	var signup = signupTemplate({
	    button_label: buttonLabel,
	    general_error: (errors.error || ''),
	    about_account: (ISCLOUD || thisUser ? null : about),
	    this_user: thisUser,
	    joinproject: joinproject,
	    verify_modal: verify,
	    pubkey: formfields.pubkey,
	    personal_fields: personal.html(),
	    project_fields: project.html()
	});
	$('#signup-body').html(signup);
	if (showVerify)
	{
	    sup.ShowModal('#verify_modal');
	}
	$('#signup_countries').bfhcountries({ country: formfields.country,
					      blank: false, ask: true });
	$('#signup_states').bfhstates({ country: 'signup_countries',
					state: formfields.state,
					blank: false, ask: true });
    }
    
    function clearForm($form)
    {
	$form.find('input:text, input:password, select, textarea').val('');
    }

    function formatter(fieldString, errors)
    {
	var result = $('<div/>');
	var fields = $(fieldString);
	fields.each(function (index, item) {
	    if (item.dataset)
	    {
  		var key = item.dataset['key'];
		var wrapper = $('<div>');
		wrapper.addClass('sidebyside-form');
		wrapper.addClass('form-group');
		wrapper.append(item);

		if (_.has(errors, key))
		{
		    wrapper.addClass('has-error');
		    wrapper.append('<label class="control-label" ' +
				   'for="inputError">' + _.escape(errors[key]) +
				   '</label>');
		}
		result.append(wrapper);
	    }
	});
	return result;
    }

    // Better version.
    function Newformatter(fieldString, errors)
    {
	var root   = $(fieldString);
	var list   = root.find('.format-me');
	list.each(function (index, item) {
	    if (item.dataset) {
		var key     = item.dataset['key'];
		var wrapper = $('<div></div>');
		wrapper.addClass('sidebyside-form');
		wrapper.addClass('form-group');
		wrapper.html($(item).clone());

		if (_.has(errors, key))
		{
		    wrapper.addClass('has-error');
		    wrapper.append('<label class="control-label" ' +
				   'for="inputError">' + _.escape(errors[key]) +
				   '</label>');
		}
		$(item).after(wrapper);
		$(item).remove();
	    }
	});
	return root;
    }

    $(document).ready(initialize);
});
