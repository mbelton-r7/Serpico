# encoding: ASCII-8BIT
require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'haml'
require 'zipruby'
require 'net/ldap'
require 'json'

#serpico handlers
require './model/master'
require './helpers/helper'
require './helpers/sinatra_ssl'
require './helpers/xslt_generation'

## SSL Settings
# Insert your cert and uncomment me
set :ssl_certificate, "./cert.pem"
set :ssl_key, "./key.pem"
set :bind, "0.0.0.0"

## Global variables
set :finding_types, [ "Web Application","Network Services", "Best Practice", "Compliance", "Database", "Network Internal", "Router Configuration","Social Engineering", "Physical", "Wireless", "Network Security", "System Security", "Logging and Auditing"]
set :effort, ["LOW","MEDIUM","HARD"]
set :assessment_types, ["External", "Internal", "Internal/External", "Wireless", "Web Application", "DoS"]
set :status, ["EXPLOITED"]

## LDAP Settings
set :ldap, false
set :domain, ""
set :dc, ""

enable :sessions 
    
### Basic Routes

# Used for 404 responses
not_found do
    "Sorry, I don't know this page."
end

# Default Page
get '/' do
    redirect to("/reports/list")
end

# Handles the consultant information settings
get '/info' do
    redirect to("/") unless valid_session?

    @user = User.first(:username => get_username)
    
    if !@user
        @user = User.new
        @user.auth_type = "AD"
        @user.username = get_username
        @user.type = "User"
        @user.save
    end
    
    haml :info, :encode_html => true
end

# Save the consultant information into the database
post '/info' do
    redirect to("/") unless valid_session?
    
    user = User.first(:username => get_username)
    
    if !user
        user = User.new
        user.auth_type = "AD"
        user.username = get_username
        user.type = "User"
    end

    user.consultant_email = params[:email] 
    user.consultant_phone = params[:phone] 
    user.consultant_title = params[:title]  
    user.consultant_name = params[:name] 
    user.save

    redirect to("/info")
end

get '/login' do
    redirect to("/reports/list")
end

post '/login' do
    user = User.first(:username => params[:username])
    
    if user and user.auth_type == "Local"
    
        usern = User.authenticate(params["username"], params["password"])
    
        if usern and session[:session_id]
            # replace the session in the session table
            # TODO : This needs an expiration, session fixation
            @del_session = Sessions.first(:username => "#{usern}")
            @del_session.destroy if @del_session
            @curr_session = Sessions.create(:username => "#{usern}",:session_key => "#{session[:session_id]}")
            @curr_session.save
    
        end
    else
		if options.ldap
			#try AD authentication
			usern = params[:username]
			data = url_escape_hash(request.POST)           
 
			user = "#{options.domain}\\#{data["username"]}"
			ldap = Net::LDAP.new :host => "#{options.dc}", :port => 636, :encryption => :simple_tls, :auth => {:method => :simple, :username => user, :password => params[:password]}    

			if ldap.bind
			   # replace the session in the session table
			   @del_session = Sessions.first(:username => "#{usern}")
			   @del_session.destroy if @del_session
			   @curr_session = Sessions.create(:username => "#{usern}",:session_key => "#{session[:session_id]}")
			   @curr_session.save
			end
		end
    end
  
    redirect to("/")
end

## We use a persistent session table, one session per user; no end date
get '/logout' do
  if session[:session_id]
    sess = Sessions.first(:session_key => session[:session_id])
    if sess
      sess.destroy
    end
  end

    redirect to("/")
end

# rejected access (admin functionality)
get "/no_access" do
    return "Sorry. You Do Not have access to this resource."
end

######
# Admin Interfaces
######

get '/admin/' do
    redirect to("/no_access") if not is_administrator?
    @admin = true
    
    haml :admin, :encode_html => true
end

get '/admin/add_user' do
    redirect to("/no_access") if not is_administrator?

    @admin = true
    
    haml :add_user, :encode_html => true
end

# serve a copy of the code
get '/admin/pull' do
   redirect to("/no_access") if not is_administrator?

	if File.exists?("./export.zip")
		send_file "./export.zip", :filename => "export.zip", :type => 'Application/octet-stream'
	else
		"No copy of the code available. Run scripts/make_export.sh."
	end
end

# Create a new user
post '/admin/add_user' do
    redirect to("/no_access") if not is_administrator?

    user = User.first(:username => params[:username])
    
    if user
        if params[:password]
            # we have to hardcode the input params to prevent param pollution
            user.update(:type => params[:type], :auth_type => params[:auth_type], :password => params[:password])
        else
            # we have to hardcode the params to prevent param pollution
            user.update(:type => params[:type], :auth_type => params[:auth_type])
        end
    else
        user = User.new
        user.username = params[:username]
        user.password = params[:password]
        user.type = params[:type]
        user.auth_type = params[:auth_type]
        user.save
    end 

    redirect to('/admin/list_user')
end

get '/admin/list_user' do
    redirect to("/no_access") if not is_administrator?
    @admin = true
    @users = User.all
    
    haml :list_user, :encode_html => true
end

get '/admin/edit_user/:id' do
    redirect to("/no_access") if not is_administrator?

    @user = User.first(:id => params[:id])
    
    haml :add_user, :encode_html => true
end

get '/admin/delete/:id' do
    redirect to("/no_access") if not is_administrator?
    
    @user = User.first(:id => params[:id])
    @user.destroy if @user
    
    redirect to('/admin/list_user')
end 

get '/admin/add_user/:id' do
    redirect to("/no_access") if not is_administrator?

    @users = User.all(:order => [:username.asc])
    @report = Reports.first(:id => params[:id])
    @admin = true
    
    haml :add_user_report, :encode_html => true
end

post '/admin/add_user/:id' do
    redirect to("/no_access") if not is_administrator?

    report = Reports.first(:id => params[:id])

    if report == nil
        return "No Such Report"
    end

    authors = report.authors
    
    if authors
        authors = authors.push(params[:author])
    else
        authors = ["#{params[:author]}"] 
    end
    
    report.authors = authors
    report.save
    
    redirect to("/reports/list")
end

get '/admin/del_user_report/:id/:author' do
    redirect to("/no_access") if not is_administrator?

    report = Reports.first(:id => params[:id])

    if report == nil
        return "No Such Report"
    end

    authors = report.authors
    
    if authors
        authors = authors - ["#{params[:author]}"]
    end
    
    report.authors = authors
    report.save
    
    redirect to("/reports/list")
end

######
# Template Document Routes
######

# These are the master routes, they control the findings database

# List Available Templated Findings
get '/master/findings' do
    redirect to("/no_access") if not is_administrator?

    @findings = TemplateFindings.all(:order => [:title.asc])
    @master = true

    haml :findings_list, :encode_html => true
end

# Show only certain findings
#	This isn't implemented, should probably remove it =/
get '/master/findings/f/:type' do
    redirect to("/no_access") if not is_administrator?

    @findings = TemplateFindings.all(:type => params[:type], :order => [:title.asc])
    @master = true

    haml :findings_list, :encode_html => true
end

# Create a new templated finding
get '/master/findings/new' do
    redirect to("/no_access") if not is_administrator?

    @master = true
    
    haml :create_finding, :encode_html => true
end

# Create the finding in the DB
post '/master/findings/new' do
    redirect to("/no_access") if not is_administrator?
    
    data = url_escape_hash(request.POST)

    data["dread_total"] = data["damage"].to_i + data["reproducability"].to_i + data["exploitability"].to_i + data["affected_users"].to_i + data["discoverability"].to_i
	
    @finding = TemplateFindings.new(data)
    @finding.save

    redirect to('/master/findings')
end

# Edit the templated finding
get '/master/findings/:id/edit' do
    redirect to("/no_access") if not is_administrator?
    
    @master = true

    # Check for kosher name in report name
    id = params[:id]
    
    # Query for all Findings
    @finding = TemplateFindings.first(:id => id)
	@templates = Xslt.all()

    if @finding == nil
        return "No Such Finding"
    end
        
    haml :findings_edit, :encode_html => true
end

# Edit a finding in the report
post '/master/findings/:id/edit' do
    redirect to("/no_access") if not is_administrator?

    # Check for kosher name in report name
    id = params[:id]
        
    # Query for all Findings
    @finding = TemplateFindings.first(:id => id)

    if @finding == nil
        return "No Such Finding"
    end

    data = url_escape_hash(request.POST)

    if data["approved"] == "on"
        data["approved"] = true
    else  
        data["approved"] = false
    end
    
    data["dread_total"] = data["damage"].to_i + data["reproducability"].to_i + data["exploitability"].to_i + data["affected_users"].to_i + data["discoverability"].to_i

    # Update the finding with templated finding stuff
    @finding.update(data)

    redirect to("/master/findings")
end

# Delete a template finding
get '/master/findings/:id/delete' do
    redirect to("/no_access") if not is_administrator?

    # Check for kosher name in report name
    id = params[:id]
        
    # Query for all Findings
    @finding = TemplateFindings.first(:id => id)

    if @finding == nil
        return "No Such Finding"
    end

    # Update the finding with templated finding stuff
    @finding.destroy

    redirect to("/master/findings")
end

# preview a finding
get '/master/findings/:id/preview' do
    redirect to("/no_access") if not is_administrator?

    # Check for kosher name in report name
    id = params[:id]
        
    # Query for all Findings
    @finding = TemplateFindings.first(:id => id)
    
    if @finding == nil
        return "No Such Finding"
    end
    
    ## We have to do some hackery here for wordml 
    findings_xml = ""
    findings_xml << "<findings_list>"
    findings_xml << @finding.to_xml
    findings_xml << "</findings_list>"
    
    findings_xml = meta_markup_unencode(findings_xml, nil)
        
    # this is the master db so we have to do a bait and switch
    # The other option is creating a master finding specific docx
    findings_xml = findings_xml.gsub("<template_findings>","<findings>")        
    findings_xml = findings_xml.gsub("</template_findings>;","</template_findings>")
    
    report_xml = "#{findings_xml}"

	xslt_elem = Xslt.first(:finding_template => true)

	if xslt_elem

		# Push the finding from XML to XSLT
		xslt = Nokogiri::XSLT(File.read(xslt_elem.xslt_location))

		docx_xml = xslt.transform(Nokogiri::XML(report_xml))

		# We use a temporary file with a random name
		rand_file = "./tmp/#{rand(36**12).to_s(36)}.docx"

		# Create a temporary copy of the finding_template
		FileUtils::copy_file(xslt_elem.docx_location,rand_file)

		# A better way would be to create the zip file in memory and return to the user, this is not ideal
		Zip::Archive.open(rand_file, Zip::CREATE) do |zipfile|
			zipfile.add_or_replace_buffer('word/document.xml',
										  docx_xml.to_s)
		end

		send_file rand_file, :type => 'docx', :filename => "#{@finding.title}.docx"

	else
		"You don't have a Finding Template (did you delete the temp?) -_- ... If you're an admin go to <a href='/admin/templates/add'>here</a> to add one.'"
	end
end

# Export a findings database
get '/master/export' do
    redirect to("/no_access") if not is_administrator?

	json = ""
	
	findings = TemplateFindings.all

	local_filename = "./tmp/#{rand(36**12).to_s(36)}.json"
    File.open(local_filename, 'w') {|f| f.write(JSON.pretty_generate(findings)) }

	send_file local_filename, :type => 'json', :filename => "template_findings.json"
end

# Import a findings database
get '/master/import' do
    redirect to("/no_access") if not is_administrator?
	
	haml :import_templates
end

# Import a findings database
post '/master/import' do
    redirect to("/no_access") if not is_administrator?

	# reject if the file is above a certain limit
	if params[:file][:tempfile].size > 1000000
		return "File too large. 1MB limit"
	end	
	
	json_file = params[:file][:tempfile].read
	line = JSON.parse(json_file)
	
	line.each do |j|
		j["id"] = nil
 
		finding = TemplateFindings.first(:title => j["title"])

		if finding
			#the finding title already exists in the database
			if finding["overview"] == j["overview"] and finding["remediation"] == j["remediation"]
				# the finding already exists, ignore it
			else
				# it's a modified finding
				j["title"] = "#{j['title']} - [Uploaded Modified Templated Finding]"
				j["approved"] = false
				f = TemplateFindings.create(j)
				f.save
			end
		else
			j["approved"] = false
			f = TemplateFindings.first_or_create(j)
			f.save
		end
	end
	redirect to("/master/findings")
end

# Manage Templated Reports
get '/admin/templates' do
    redirect to("/no_access") if not is_administrator?
    
    @admin = true

    # Query for all Findings
    @templates = Xslt.all(:order => [:report_type.asc])
    
    haml :template_list, :encode_html => true       
end

# Manage Templated Reports
get '/admin/templates/add' do
    redirect to("/no_access") if not is_administrator?
    
    @admin = true
    
    haml :add_template, :encode_html => true       
end

# Manage Templated Reports
get '/admin/templates/:id/download' do
    redirect to("/no_access") if not is_administrator?
    
    @admin = true

    xslt = Xslt.first(:id => params[:id])

    send_file xslt.docx_location, :type => 'docx', :filename => "#{xslt.report_type}.docx"
end


get '/admin/delete/templates/:id' do
    redirect to("/no_access") if not is_administrator?
    
    @xslt = Xslt.first(:id => params[:id])

	if @xslt
		@xslt.destroy
		File.delete(@xslt.xslt_location)
		File.delete(@xslt.docx_location)
	end
    redirect to('/admin/templates')
end 


# Manage Templated Reports
post '/admin/templates/add' do
    redirect to("/no_access") if not is_administrator?
    
    @admin = true

	xslt_file = "./templates/#{rand(36**36).to_s(36)}.xslt"
	
	# reject if the file is above a certain limit
	if params[:file][:tempfile].size > 100000000
		return "File too large. 10MB limit"
	end	

	docx = "./templates/#{rand(36**36).to_s(36)}.docx"
	File.open(docx, 'wb') {|f| f.write(params[:file][:tempfile].read) }	

	xslt = generate_xslt(docx)
	if xslt =~ /Error file DNE/
		return "ERROR!!!!!!"
	end

	# open up a file handle and write the attachment
	File.open(xslt_file, 'wb') {|f| f.write(xslt) }	
	
	# delete the file data from the attachment
	datax = Hash.new
	# to prevent traversal we hardcode this
	datax["docx_location"] = "#{docx}"
	datax["xslt_location"] = "#{xslt_file}"	
	datax["description"] = 	params[:description]
	datax["report_type"] = params[:report_type]	
	data = url_escape_hash(datax)
	data["finding_template"] = params[:finding_template] ? true : false
	data["status_template"] = params[:status_template] ? true : false

	@current = Xslt.first(:report_type => data["report_type"])

	if @current
		@current.update(:xslt_location => data["xslt_location"], :docx_location => data["docx_location"], :description => data["description"])
	else
		@template = Xslt.new(data)
		@template.save
	end

	redirect to("/admin/templates")
    
    haml :add_template, :encode_html => true       
end


# Manage Templated Reports
get '/admin/templates/:id/edit' do
    redirect to("/no_access") if not is_administrator?
    
    @admin = true

    # Query for all Findings
    @template = Xslt.first(:id => params[:id])
    
    haml :add_template, :encode_html => true       
 end

#####
# Reporting Routes
#####

# List current reports
get '/reports/list' do
    @reports = get_reports

    @admin = true if is_administrator?

    haml :reports_list, :encode_html => true
end

# Create a report
get '/report/new' do
    @templates = Xslt.all
    haml :new_report, :encode_html => true
end

# Create a report
post '/report/new' do
    redirect to("/") unless valid_session?
    
    data = url_escape_hash(request.POST)
    
    data["owner"] = get_username
    data["date"] = DateTime.now.strftime "%m/%d/%Y"

    @report = Reports.new(data)
    @report.save

   redirect to("/report/#{@report.id}/edit")
end

# List attachments
get '/report/:id/attachments' do
	redirect to("/") unless valid_session?
    
    id = params[:id]
    
    # Query for the first report matching the id
    @report = get_report(id)
    
    if @report == nil 
        return "No Such Report"
    end
    
    @attachments = Attachments.all(:report_id => id)
    haml :list_attachments, :encode_html => true
end

# Upload attachment menu
get '/report/:id/upload_attachments' do
	redirect to("/") unless valid_session?
    
    id = params[:id]
    
    # Query for the first report matching the id
    @report = get_report(id)
    
    if @report == nil 
        return "No Such Report"
    end
    
    @attachments = Attachments.all(:report_id => id)
    
    haml :upload_attachments, :encode_html => true
end

post '/report/:id/upload_attachments' do
	redirect to("/") unless valid_session?
    
    id = params[:id]
   
    # Query for the first report matching the id
    @report = get_report(id)
    
    if @report == nil 
        return "No Such Report"
    end

    # We use a random filename
    rand_file = "./attachments/#{rand(36**36).to_s(36)}"
    
	# reject if the file is above a certain limit
	if params[:file][:tempfile].size > 100000000
		return "File too large. 100MB limit"
	end	

	# open up a file handle and write the attachment
	File.open(rand_file, 'wb') {|f| f.write(params[:file][:tempfile].read) }	
	
	# delete the file data from the attachment
	datax = Hash.new
	# to prevent traversal we hardcode this
	datax["filename_location"] = "#{rand_file}"
	datax["filename"] = params[:file][:filename]	
	datax["description"] = CGI::escapeHTML(params[:description])
	datax["report_id"] = id
	data = url_escape_hash(datax)

	@attachment = Attachments.new(data)
	@attachment.save
	redirect to("/report/#{id}/attachments")
end

# display attachment
get '/report/:id/attachments/:att_id' do
	redirect to("/") unless valid_session?
    
    id = params[:id]
    
    # Query for the first report matching the id
    @report = get_report(id)
    
    if @report == nil 
        return "No Such Report"
    end
    
    @attachment = Attachments.first(:report_id => id, :id => params[:att_id])
    send_file @attachment.filename_location, :filename => "#{@attachment.filename}"
end

#Delete an attachment
get '/report/:id/attachments/delete/:att_id' do
	redirect to("/") unless valid_session?
    
    id = params[:id]
    
    # Query for the first report matching the id
    @report = get_report(id)
    
    if @report == nil 
        return "No Such Report"
    end
    
    @attachment = Attachments.first(:report_id => id, :id => params[:att_id])

	if @attachment == nil
		return "No Such Attachment"
	end

    File.delete(@attachment.filename_location)

    # delete the entries
    @attachment.destroy
    
	redirect to("/report/#{id}/attachments")
end


#Delete a report
get '/report/:id/remove' do
    redirect to("/") unless valid_session?
    
    id = params[:id]
    
    # Query for the first report matching the id
    @report = get_report(id)
    
    if @report == nil
        return "No Such Report"
    end
    
    # get all findings associated with the report
    @findings = Findings.all(:report_id => id)
    
    # delete the entries
    @findings.destroy
    @report.destroy
    
    redirect to("/reports/list")
end

# Edit the Report's main information; Name, Consultant, etc.
get '/report/:id/edit' do
    redirect to("/") unless valid_session?

    id = params[:id]
    
    # Query for the first report matching the report_name
    @report = get_report(id)
	@templates = Xslt.all(:order => [:report_type.asc])

    if @report == nil
        return "No Such Report"
    end
    
    haml :report_edit, :encode_html => true
end

# Edit a report
post '/report/:id/edit' do
    redirect to("/") unless valid_session?

    id = params[:id]

    data = url_escape_hash(request.POST)

    @report = get_report(id)    
    @report = @report.update(data)

    redirect to("/report/#{id}/edit")
end

# Edit the Report's Current Findings
get '/report/:id/findings' do
    redirect to("/") unless valid_session?

    @report = true
    id = params[:id]
        
    # Query for the first report matching the report_name
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end
    
    # Query for the findings that match the report_id
    @findings = Findings.all(:report_id => id, :order => [:dread_total.desc])   
    
    haml :findings_list, :encode_html => true
end

# Generate a status report from the current findings
get '/report/:id/status' do
    redirect to("/") unless valid_session?

    id = params[:id]
        
    # Query for the report
    @report = get_report(id)
        
    if @report == nil 
        return "No Such Report"
    end
    
    # Query for the findings that match the report_id
    @findings = Findings.all(:report_id => id, :order => [:dread_total.desc])   
    
    ## We have to do some hackery here for wordml 
    findings_xml = ""
    findings_xml << "<findings_list>"
    @findings.each do |finding|
        ### Let's find the diff between the original and the new overview and remediation
        master_finding = TemplateFindings.first(:id => finding.master_id)
    
        findings_xml << finding.to_xml
    end
    findings_xml << "</findings_list>"
    
    findings_xml = meta_markup_unencode(findings_xml, @report.short_company_name) 
        
    report_xml = "#{findings_xml}"

	xslt_elem = Xslt.first(:status_template => true)

	if xslt_elem

		# Push the finding from XML to XSLT
		xslt = Nokogiri::XSLT(File.read(xslt_elem.xslt_location))

		docx_xml = xslt.transform(Nokogiri::XML(report_xml))

		# We use a temporary file with a random name
		rand_file = "./tmp/#{rand(36**12).to_s(36)}.docx"

		# Create a temporary copy of the finding_template
		FileUtils::copy_file(xslt_elem.docx_location,rand_file)

		# A better way would be to create the zip file in memory and return to the user, this is not ideal
		Zip::Archive.open(rand_file, Zip::CREATE) do |zipfile|
			zipfile.add_or_replace_buffer('word/document.xml',
										  docx_xml.to_s)
		end

		send_file rand_file, :type => 'docx', :filename => "status.docx"

	else
		"You don't have a Finding Template (did you delete the temp?) -_- ... If you're an admin go to <a href='/admin/templates/add'>here</a> to add one."
	end


end

# Add a finding to the report
get '/report/:id/findings_add' do
    redirect to("/") unless valid_session?

    # Check for kosher name in report name
    id = params[:id]
    
    # Query for the first report matching the report_name
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end

    # Query for all Findings
    @findings = TemplateFindings.all(:approved => true, :order => [:title.asc])
    
    haml :findings_add, :encode_html => true
end

# Add a finding to the report
post '/report/:id/findings_add' do
    redirect to("/") unless valid_session?

    # Check for kosher name in report name
    id = params[:id]
    
    # Query for the first report matching the report_name
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end

    add_findings = params[:finding]
    
    if add_findings.size == 0
        redirect_to("/report/#{id}/edit")
    else
        add_findings.each do |finding|
            templated_finding = TemplateFindings.first(:id => finding.to_i)

            templated_finding.id = nil
            attr = templated_finding.attributes
            attr.delete(:approved)
            attr["master_id"] = finding.to_i
            @newfinding = Findings.new(attr)
            @newfinding.report_id = id
            @newfinding.save            
        end
    end

    @findings = Findings.all(:report_id => id, :order => [:dread_total.desc] )
    
    haml :findings_list, :encode_html => true
end

# Create a new finding in the report
get '/report/:id/findings/new' do
    redirect to("/") unless valid_session?

    haml :create_finding, :encode_html => true
end

# Create the finding in the DB
post '/report/:id/findings/new' do
    redirect to("/") unless valid_session?

    data = url_escape_hash(request.POST)

    data["dread_total"] = data["damage"].to_i + data["reproducability"].to_i + data["exploitability"].to_i + data["affected_users"].to_i + data["discoverability"].to_i

    id = params[:id]
    
    # Query for the first report matching the report_name
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end
    
    data["report_id"] = id

    @finding = Findings.new(data)
    @finding.save
    
    # for a parameter_pollution on report_id

    redirect to("/report/#{id}/findings")
end

# Edit the finding in a report
get '/report/:id/findings/:finding_id/edit' do
    redirect to("/") unless valid_session?

    id = params[:id]
    
    # Query for the first report matching the report_name
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end
    
    finding_id = params[:finding_id]
    
    # Query for all Findings
    @finding = Findings.first(:report_id => id, :id => finding_id)
    
    if @finding == nil
        return "No Such Finding"
    end
    
    haml :findings_edit, :encode_html => true
end

# Edit a finding in the report
post '/report/:id/findings/:finding_id/edit' do
    redirect to("/") unless valid_session?

    # Check for kosher name in report name
    id = params[:id]
    
    # Query for the report
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end
    
    finding_id = params[:finding_id]
    
    # Query for all Findings
    @finding = Findings.first(:report_id => id, :id => finding_id)
    
    if @finding == nil
        return "No Such Finding"
    end

    data = url_escape_hash(request.POST)

    data["dread_total"] = data["damage"].to_i + data["reproducability"].to_i + data["exploitability"].to_i + data["affected_users"].to_i + data["discoverability"].to_i

    # Update the finding with templated finding stuff
    @finding.update(data)

    redirect to("/report/#{id}/findings")
end

# Upload a finding from a report into the database
get '/report/:id/findings/:finding_id/upload' do
    redirect to("/") unless valid_session?

    # Check for kosher name in report name
    id = params[:id]
    
    # Query for the report
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end
    
    finding_id = params[:finding_id]
    
    # Query for the finding
    @finding = Findings.first(:report_id => id, :id => finding_id)
    
    if @finding == nil
        return "No Such Finding"
    end

    # We can't create a direct copy b/c TemplateFindings doesn't have everything findings does
    # Check model/master.rb to compare
    attr = {
                    :title => @finding.title,
                    :damage => @finding.damage,
                    :reproducability => @finding.reproducability,
                    :exploitability => @finding.exploitability,
                    :affected_users => @finding.affected_users,
                    :discoverability => @finding.discoverability,
                    :dread_total => @finding.dread_total,
                    :effort => @finding.effort,
                    :type => @finding.type,
                    :overview => @finding.overview,
                    :poc => @finding.poc,
                    :remediation => @finding.remediation,
                    :approved => false
                    }

    @new_finding = TemplateFindings.new(attr)
    @new_finding.save

    redirect to("/report/#{id}/findings")
end

# Remove a finding from the report
get '/report/:id/findings/:finding_id/remove' do
    redirect to("/") unless valid_session?

    # Check for kosher name in report name
    id = params[:id]
    
    # Query for the report
    @report = get_report(id)

    if @report == nil 
        return "No Such Report"
    end
    
    finding_id = params[:finding_id]
    
    # Query for all Findings
    @finding = Findings.first(:report_id => id, :id => finding_id)
    
    if @finding == nil
        return "No Such Finding"
    end

    # Update the finding with templated finding stuff
    @finding.destroy

    redirect to("/report/#{id}/findings")
end

# preview a finding
get '/report/:id/findings/:finding_id/preview' do
    redirect to("/") unless valid_session?

    id = params[:id]

    # Query for the report
    @report = get_report(id)
        
    if @report == nil 
        return "No Such Report"
    end
    
    # Query for the Finding
    @finding = Findings.first(:report_id => id, :id => params[:finding_id])
    
    if @finding == nil
        return "No Such Finding"
    end
    
    # this flags edited findings
    if @finding.master_id
            master = TemplateFindings.first(:id => @finding.master_id)
            @finding.overview = compare_text(@finding.overview, master.overview)
    end
    
    ## We have to do some hackery here for wordml 
    findings_xml = ""
    findings_xml << "<findings_list>"
    findings_xml << @finding.to_xml
    findings_xml << "</findings_list>"
    
    findings_xml = meta_markup_unencode(findings_xml, @report.short_company_name)

    report_xml = "#{findings_xml}"

	xslt_elem = Xslt.first(:finding_template => true)

	if xslt_elem

		# Push the finding from XML to XSLT
		xslt = Nokogiri::XSLT(File.read(xslt_elem.xslt_location))

		docx_xml = xslt.transform(Nokogiri::XML(report_xml))

		# We use a temporary file with a random name
		rand_file = "./tmp/#{rand(36**12).to_s(36)}.docx"

		# Create a temporary copy of the finding_template
		FileUtils::copy_file(xslt_elem.docx_location,rand_file)

		# A better way would be to create the zip file in memory and return to the user, this is not ideal
		Zip::Archive.open(rand_file, Zip::CREATE) do |zipfile|
			 zipfile.add_or_replace_buffer('word/document.xml',
				 docx_xml.to_s)
		end

		send_file rand_file, :type => 'docx', :filename => "#{@finding.title}.docx"

	else

		"You don't have a Finding Template (did you delete the default one?) -_- ... If you're an admin go to <a href='/admin/templates/add'>here</a> to add one."

	end
end

# Generate the report
get '/report/:id/generate' do
    redirect to("/") unless valid_session?

    id = params[:id]
        
    # Query for the report
    @report = get_report(id)
        
    if @report == nil 
        return "No Such Report"
    end

    user = User.first(:username => get_username)

   if user
    @report.consultant_name = user.consultant_name 
    @report.consultant_phone = user.consultant_phone
    @report.consultant_email = user.consultant_email
    @report.consultant_title = user.consultant_title
   else
    @report.consultant_name = ""
    @report.consultant_phone = ""
    @report.consultant_email = ""
    @report.consultant_title = ""
   end 
   @report.save
      
    # Query for the findings that match the report_id
    @findings = Findings.all(:report_id => id, :order => [:dread_total.desc])   
    
    ## We have to do some hackery here for wordml 
    findings_xml = ""
    findings_xml << "<findings_list>"
         
    @findings.each do |finding|
        
        # This flags new or edited findings
        if finding.master_id
            master = TemplateFindings.first(:id => finding.master_id)
            if master
               finding.overview = compare_text(finding.overview, master.overview)
               finding.remediation = compare_text(finding.remediation, master.remediation)
            else
               finding.overview = compare_text(finding.overview, nil)
               finding.remediation = compare_text(finding.remediation, nil)
            end
        else
            finding.overview = compare_text(finding.overview, nil)
            finding.remediation = compare_text(finding.remediation, nil)
        end     
        findings_xml << finding.to_xml
        
    end
    findings_xml << "</findings_list>"

    # Replace the stub elements with real XML elements
    findings_xml = meta_markup_unencode(findings_xml, @report.short_company_name)
    
    report_xml = "<report>#{@report.to_xml}#{findings_xml}</report>"

	xslt_elem = Xslt.first(:report_type => @report.report_type)

    # Push the finding from XML to XSLT
    xslt = Nokogiri::XSLT(File.read(xslt_elem.xslt_location))

    docx_xml = xslt.transform(Nokogiri::XML(report_xml))
    
    # We use a temporary file with a random name
    rand_file = "./tmp/#{rand(36**12).to_s(36)}.docx"
    
    # Create a temporary copy of the word doc
    FileUtils::copy_file(xslt_elem.docx_location,rand_file)
    
    # A better way would be to create the zip file in memory and return to the user, this is not ideal
    Zip::Archive.open(rand_file, Zip::CREATE) do |zipfile|
         zipfile.add_or_replace_buffer('word/document.xml',
           docx_xml.to_s)
    end
    
    send_file rand_file, :type => 'docx', :filename => "#{@report.report_name}.docx"
end

# Helper Functions

# Return if the user has a valid session or not
def valid_session?
  return Sessions.is_valid?(session[:session_id])  
end

# Get the current users type
def user_type
  return Sessions.type(session[:session_id])
end

# Get the current users, username
def get_username
    return Sessions.get_username(session[:session_id])
end

# Check if the user is an administrator
def is_administrator?
  return true if Sessions.type(session[:session_id]) == "Administrator"
end

# Grab a specific report
def get_report(id)
    if is_administrator?
        return Reports.first(:id => id)
    else
        report = Reports.first(:id => id)
        if report
            authors = report.authors
            return report if report.owner == get_username
            if authors
              return report if authors.include?(get_username)
            end
        end
    end
end

# List out the reports
def get_reports
    if is_administrator?
        return Reports.all
    else
        reports = Reports.all
        reports_array = []
        reports.each do |report|
            next unless report and get_username
            authors = report.authors
            reports_array.push(report) if report.owner == get_username 
            if authors
                reports_array.push(report) if authors.include?(get_username)
            end
        end
        return nil unless reports_array
        return reports_array            
    end
end
