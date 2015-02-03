package S44Zombies;
use strict;
use warnings;
use SpadsPluginApi;
use Data::Dumper qw(Dumper);
use Mojo::IOLoop;
use Mojo::UserAgent;
use 5.20.1;

use experimental qw(signatures postderef);
use JSON::MaybeXS;
use Digest::xxHash qw(xxhash_hex);

no warnings 'redefine';

# TODO: queue API calls and only remove them from queue on confirm by
# server that they were accepted

sub getVersion { '0.1' }
sub getRequiredSpadsVersion { '0.11' }

my %globalPluginParams = ( commandsFile => ['notNull'],
                           helpFile => ['notNull'] );
sub getParams { return [\%globalPluginParams,{}]; }

my $host = "localhost:3000";

sub eventLoop {
    my $id = Mojo::IOLoop->timer(0.05 => sub {});
    Mojo::IOLoop->one_tick;
    Mojo::IOLoop->remove($id);
};

my $ua = Mojo::UserAgent->new;

sub dispatch_message ($db, $game_id, $autohost, $message) {
    if ($message =~ s/team-ready //) {
        say "got a team ready message: $message";
        my ($player_name, $team_id) = split '\|', $message;
        $ua->get("$host/account/$player_name" => sub ($self, $tx) {
            my $json = $tx->res->json;
            say "got a team-ready response for $player_name";
            say Dumper($json);
            $json->{teamID} = $team_id;
            $json->{money} //= 150000;
            $autohost->sendChatMessage("/luarules spawn-team  " . encode_json($json));
        });

    } elsif ($message =~ s/save-unit //) {
        say "got a save-data message: $message";
        my $saved = 0;
        my $data = decode_json($message);
        my $player_name = $data->{name};
        $ua->post("$host/army/$player_name" => json => $data->{unit} => sub ($self, $tx) {
            $saved = 1;
        });

    } elsif ($message =~ s/reward //) {
        say "got a reward: $message";
        my $success = 0;
        my $data = decode_json($message);
        my $player_name = $data->{name};
        $ua->post("$host/bank/$player_name" => json => $data => sub ($self, $tx) {
            $success = 1;
        });
    }
}

sub game_end ($game_id) {
    $ua->post("$host/end/$game_id" => sub ($self, $tx) { });
}

sub new ($class) {
    my $self = {};
    bless($self, $class);
    my $autohost = getSpringInterface();
    my $db;
    my $game_id;
    my %message_hash;
    my $num_players_running_sim;
    my $seed;

    addSpringCommandHandler({SERVER_STARTPLAYING => sub {
        $game_id = $autohost->{gameId};
        say Dumper($autohost);
        $seed = rand;
        %message_hash = ();

        # get them by IP address and count?
        # we're mostly interested in the number of spring sims running, which
        # relates to how many copies of a particular message we will get.
        # note: this ignores bots, which is a pain. they're not in the players
        # hash at all.
        my @players = keys $autohost->{players}->%*;
        $num_players_running_sim = scalar @players;
        $ua->post("$host/start/$game_id" => json => [@players] => sub ($self, $tx) { });
    }});

    addSpringCommandHandler({PLAYER_JOINED => sub { $num_players_running_sim++ }});
    addSpringCommandHandler({PLAYER_LEFT => sub { $num_players_running_sim-- }});

    addSpringCommandHandler({PLAYER_CHAT => sub ($message_type, $source_player, $dest_player, $chat_data) {
        say "player $source_player sent '$chat_data' to player $dest_player";
        my $fingerprint = xxhash_hex($chat_data, $seed);
        $message_hash{$fingerprint} //= { seen => 0, sent => 0};
        my $message = $message_hash{$fingerprint};
        my $seen = ++$message->{seen};
        my $sent = $message->{sent};
        # this could probably also use a minimum of 2, but that would make my
        # testing life difficult, and zombies isn't a 1v1 game.
        say "message has fingerprint $fingerprint has been seen " . $seen . " times";
        if ($seen >= $num_players_running_sim / 2 and not $sent) {
            $message->{sent} = time;
            dispatch_message($db, $game_id, $autohost, $chat_data);
        } 
    }});

    addSpringCommandHandler({SERVER_GAMEOVER => sub { say "sending game end: $game_id"; game_end($game_id) }});
    # in case it fails for some reason
    addSpringCommandHandler({SERVER_QUIT => sub { say "sending game end: $game_id"; game_end($game_id) }});

    addSpadsCommandHandler({hq => sub ($source, $user, $params, $checkOnly) {
        $ua->get("$host/hq/$user" => sub ($ua, $tx) {
            sayPrivate($user, "server says: " . $tx->res->text);
        });
    }});
    
    return $self;
}

1;
