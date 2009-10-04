package Finance::Quote::MorningstarJp;
require 5.005;

use strict;

use vars qw/$VERSION $MORNINGSTAR_SNAPSHOT_JP_URL $MORNINGSTAR_BASIC_JP_URL $MORNINGSTAR_RATING_JP_URL/;

use Encode;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTML::Parser;
use XML::XPath;

$VERSION = '1.0';

$MORNINGSTAR_SNAPSHOT_JP_URL = 'http://www.morningstar.co.jp/new_fund/sr_detail_snap.asp?fnc=';

sub methods { return ( morningstar_jp => \&morningstar_jp ); }

{
   my @labels = qw/symbol name last date currency net method/;

   sub labels { return ( morningstar_jp => \@labels ); }
}

sub morningstar_jp
{
   my $quoter  = shift;
   my @symbols = @_;

   return unless @symbols;

   my ( $user_agent, $snapshot_url, $snapshot_reply, $snapshot_content, $snapshot_root, $snapshot_parser, %funds );

   foreach my $symbol (@symbols)
   {
       $user_agent = $quoter->user_agent;

       $snapshot_url   = $MORNINGSTAR_SNAPSHOT_JP_URL . $symbol;
       $snapshot_reply = $user_agent->request( GET($snapshot_url) );

       unless ( $snapshot_reply->is_success() )
       {
           foreach my $symbol (@symbols)
           {
               $funds{ $symbol, 'success' }  = 0;
               $funds{ $symbol, 'errormsg' } = 'HTTP failure';
           }
           return wantarray ? %funds : \%funds;
       }

       $snapshot_content = decode( 'shiftjis', $snapshot_reply->content() );

       $snapshot_root = parseHtml($snapshot_content);

       if ($snapshot_root)
       {
           $snapshot_parser = XML::XPath->new( context => $snapshot_root );

           # XPath to the fund name
           if ( scalar( my @fundname_list = $snapshot_parser->findnodes("/descendant::node()/child::comment()[contains(self::comment(), '\x{25bd}\x{30d5}\x{30a1}\x{30f3}\x{30c9}\x{540d}')]/following-sibling::node()/tr/td/td/span/b/text()")->get_nodelist() ) > 0 )
           {
               $funds{ $symbol, 'name' }     = $fundname_list[0]->toString();
               $funds{ $symbol, 'symbol' }   = $symbol;
               $funds{ $symbol, 'currency' } = 'JPY';
               $funds{ $symbol, 'timezone' } = 'Asia/Japan';
               $funds{ $symbol, 'success' }  = 1;
               $funds{ $symbol, 'method' }   = 'morningstar_jp';

               # XPath to the date
               if ( scalar( my @date_list = $snapshot_parser->findnodes("/descendant::node()[contains(child::comment(), '\x{57fa}\x{672c}\x{60c5}\x{5831}')]/table/tr/table/tr/td/div/text()")->get_nodelist() ) > 0 )
               {
                   my $date = $date_list[0]->toString();
                   $date =~ m/\x{57fa}\x{6e96}\x{4fa1}\x{984d}\((\d{4})-(\d{2})-(\d{2})\)/;
                   $date = sprintf( "%02d/%02d/%02d", $2, $3, $1 % 100 );

                   $funds{ $symbol, 'date' } = $date;
               }

               # XPath to the last price
               if ( scalar( my @last_list = $snapshot_parser->findnodes("/descendant::node()[contains(child::comment(), '\x{57fa}\x{672c}\x{60c5}\x{5831}')]/table/tr/table/tr/td[2]/div/text()")->get_nodelist() ) > 0 )
               {
                   my $last = $last_list[0]->toString();
                   $last =~ s/[, ]//g;
                   $last =~ s/\x{5186}//g;

                   $funds{ $symbol, 'last' } = $last / 10000;
               }

               # XPath to the net price change
               if ( scalar( my @net_list = $snapshot_parser->findnodes("/descendant::node()[contains(child::comment(), '\x{57fa}\x{672c}\x{60c5}\x{5831}')]/table/tr/table/tr[2]/tr/td[2]/div/text()")->get_nodelist() ) > 0 )
               {
                   my $net = $net_list[0]->toString();
                   $net =~ s/[, ]//g;
                   $net =~ s/\x{5186}//g;

                   $funds{ $symbol, 'net' } = $net;
               }
           }
       }

       unless ( $funds{ $symbol, 'success' } )
       {
           $funds{ $symbol, 'success' }  = 0;
           $funds{ $symbol, 'errormsg' } = 'Fund name not found';
       }
   }

   return %funds if wantarray;
   return \%funds;
}

sub parseHtml
{
   my ($content) = @_;

   my $xml_root;
   my $xml_current;
   my $html_parser = new HTML::Parser(
       api_version        => 3,
       case_sensitive     => 1,
       empty_element_tags => 1,
       handlers           => {
           comment => [
               sub {
                   my ($token0) = @_;

                   my $comment_node = new XML::XPath::Node::Comment($token0);
                   $xml_current->appendChild($comment_node);
               },
               'token0'
           ],
           end => [
               sub {
                   $xml_current = $xml_current->getParentNode();
               },
           ],
           end_document => [
               sub {
                   $xml_current = undef;
               },
           ],
           process => [
               sub {
                   my ( $tagname, $token0 ) = @_;

                   my $process_node = new XML::XPath::Node::PI( $tagname, $token0 );
                   $xml_current->appendChild($process_node);
               },
               'tagname, token0'
           ],
           start => [
               sub {
                   my ( $tagname, $attrseq, $attr ) = @_;

                   my $element_node = new XML::XPath::Node::Element($tagname);
                   foreach my $attr_key (@$attrseq)
                   {
                       my $attribute_node = new XML::XPath::Node::Attribute( $attr_key, $attr->{$attr_key} );
                       $element_node->appendAttribute($attribute_node);
                   }
                   $xml_current->appendChild($element_node);
                   $xml_current = $element_node;
               },
               'tagname, attrseq, attr'
           ],
           start_document => [
               sub {
                   $xml_root    = new XML::XPath::Node::Element('root');
                   $xml_current = $xml_root;
               },
           ],
           text => [
               sub {
                   my ($dtext) = @_;

                   my $text_node = new XML::XPath::Node::Text($dtext);
                   $xml_current->appendChild($text_node);
               },
               'dtext'
           ],
       },
   );

   $html_parser->parse($content);

   return $xml_root;
}

1;

=head1 NAME

Finance::Quote::MorningstarJP - Obtain fund prices from Morningstar Japan

=head1 SYNOPSIS

use Finance::Quote;

$q = Finance::Quote->new;

%fundinfo = $q->fetch("morningstar_jp","fund name");

=head1 DESCRIPTION

This module obtains information about Japanese fund prices from
http://www.morningstar.co.jp/.

=head1 FUND NAMES

Visit http://www.morningstar.co.jp/, and search for your fund.  Open the
link to the fund information, and you will get a URL like this:

 http://www.morningstar.co.jp/new_fund/sr_detail_snap.asp?fnc=51311021

The fund name is the alphanumerical characters after "fnc=" (in this
case, it's 51311021)

=head1 LABELS RETURNED

Information available from Japanese funds may include the following labels:

 symbol
 name
 last
 date
 currency
 net
 method

The prices are updated at the end of each bank day.

=cut
