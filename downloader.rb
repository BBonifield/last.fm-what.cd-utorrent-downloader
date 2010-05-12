require 'rubygems'
require 'mechanize'
require 'net/http'
require 'xmlsimple'
require 'curb'
require 'yaml'

# = Synopsis
# This script uses the last.fm API, what.cd website, and uTorrent WebUI to automatically download
# album torrents each time a user "Loves" a track.

# load config
begin
    APP_CONFIG = YAML.load_file("config.yml")
rescue Exception => e
    print "Failed to load config file.  Have you created your own config file yet?\n"
    exit
end

albums_to_get        = [] # array of album hashes
torrents_to_get      = [] # array of torrent download URLs
successful_additions = [] # array of albums that were actually downloaded

# if running via a CRON job, only grab newly loved tracks from the last.fm API
cutoff_time =
if APP_CONFIG['cron_interval'] == 0
   -1
else
   (Time.new - (APP_CONFIG['cron_interval']*60)).utc.to_i
end

url        = "http://ws.audioscrobbler.com/2.0/?method=user.getlovedtracks&user=#{APP_CONFIG['last_user']}&api_key=#{APP_CONFIG['last_api_key']}"
resp       = Net::HTTP.get_response(URI.parse(url))
loved_data = XmlSimple.xml_in(resp.body)
if loved_data['lovedtracks'] && loved_data['lovedtracks'][0]['track'].any?
    loved_data['lovedtracks'][0]['track'].each do |track|
        # skip the remaining tracks because they're all below the cutoff time
        break if track['date'][0]['uts'].to_i < cutoff_time
        
        artist     = track['artist'][0]['name'][0]
        name       = track['name'][0]
        url        = "http://ws.audioscrobbler.com/2.0/?method=track.getinfo&api_key=#{APP_CONFIG['last_api_key']}&artist=#{URI.encode(artist)}&track=#{URI.encode(name)}"
        resp       = Net::HTTP.get_response(URI.parse(url))
        track_data = XmlSimple.xml_in(resp.body)
        
        if track_data['track']
            # some tracks don't have album information, so skip over them
            if track_data['track'][0]['album']
                album                = track_data['track'][0]['album'][0]
                album_hash           = {}
                album_hash['artist'] = album['artist'][0]
                album_hash['title']  = album['title'][0]
                albums_to_get.push( album_hash )
            else
                APP_CONFIG['verbose'] and printf "NOTICE: Loved track information doesn't contain album information: %s - %s.  Skipping.\n", artist, name
            end
        else
            APP_CONFIG['verbose'] and printf "WARNING: Couldn't load Last.fm track details for track: %s - %s.  Skipping.\n", artist, name
        end
    end
else
    APP_CONFIG['verbose'] and printf "ERROR: Couldn't load Last.fm loved tracks data for user: %s.  Exiting.\n", APP_CONFIG['last_user']
    exit
end

# grab the torrent for each album from what
if albums_to_get.any?
    a = Mechanize.new
    a.get('http://what.cd/') do |page|
        # Click login link
        login_page = a.click(page.link_with(:text => "Login"))
        # Submit login page
        idx_page = login_page.form_with(:action => "login.php") do |f|
            f.username = APP_CONFIG['what_user']
            f.password = APP_CONFIG['what_password']
        end.submit
        # Get to the search page
        search_page = a.click(idx_page.link_with(:href => "torrents.php"))
    
        # Search for each album
        albums_to_get.each do |album|
            results_page = search_page.form_with(:name => "filter") do |f|
                f.artistname = album['artist']
                f.groupname  = album['title']
                f.encoding   = APP_CONFIG['what_encoding']
                f.order_by   = "snatched"
            end.submit
        
            # since we're ordering by number of snatches, grab the link for the most popular torrent
            dl_links = results_page.links_with(:text => 'DL', :href => /^torrents\.php\?action=download/)
            if dl_links.any?
                album['url'] = "http://what.cd/" + dl_links[0].href
                torrents_to_get.push( album )
            else
                APP_CONFIG['verbose'] and printf "NOTICE: Failed to locate What.cd torrent for album: %s - %s.  Skipping.\n", album['artist'], album['title']
            end
        end
    end
end

# upload each torrent to uTorrent WebUI
if torrents_to_get.any?
    a = Mechanize.new
    a.auth(APP_CONFIG['utorrent_user'], APP_CONFIG['utorrent_password'])
    a.get(APP_CONFIG['utorrent_url']) do |page|
        torrents_to_get.each do |torrent|
            c = Curl::Easy.new(torrent['url'])
            if c.perform
                torrent_name = nil
                # get true torrent file name from the cURL headers
                c.header_str.split(/\r\n/).each do |line|
                    if /^Content-Disposition/.match(line)
                        torrent_name = line.gsub(/^.+filename=\"(.+)\"$/, "\\1")
                        break
                    end
                end
                if torrent_name
                    # store torrent file so it can be uploaded to uTorrent WebUI
                    open(torrent_name, "wb") do |file|
                        file.write( c.body_str )
                    end
                    # upload it
                    page.form_with(:action => "./?action=add-file") do |f|
                        f.file_uploads.first.file_name = torrent_name
                    end.submit
                    # cleanup
                    File.delete(torrent_name)
                    
                    successful_additions.push(torrent)
                else
                    APP_CONFIG['verbose'] and printf "WARNING: Failed to parse torrent filename for album: %s - %s (%s).  Skipping.", torrent['artist'], torrent['title'], url
                end
            end
        end
    end
end

# print stats
if APP_CONFIG['verbose']
    printf "Successfully processed %d torrent(s).\n", successful_additions.length
    successful_additions.each do |torrent|
        printf "\t%s - %s\n", torrent['artist'], torrent['title']
    end
end
