"#######################################################################
" Copyright (C) 2007 Adrien Friggeri.
"
" This program is free software; you can redistribute it and/or modify
" it under the terms of the GNU General Public License as published by
" the Free Software Foundation; either version 2, or (at your option)
" any later version.
"
" This program is distributed in the hope that it will be useful,
" but WITHOUT ANY WARRANTY; without even the implied warranty of
" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
" GNU General Public License for more details.
"
" You should have received a copy of the GNU General Public License
" along with this program; if not, write to the Free Software Foundation,
" Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.  
" 
" Contributors:     Adrien Friggeri <adrien@friggeri.net>
"               Pigeond <http://pigeond.net/blog/>
"               Justin Sattery <justin.slattery@fzysqr.com>
"               Lenin Lee <lenin.lee@gmail.com>
"               Conner McDaniel <connermcd@gmail.com>
"
" Forked By: Preston M.[BOYPT] <pentie@gmail.com>
" Repository: https://bitbucket.org/pentie/vimrepress
"
" URL:         http://www.friggeri.net/projets/vimblog/
"           http://pigeond.net/blog/2009/05/07/vimpress-again/
"           http://pigeond.net/git/?p=vimpress.git
"           http://fzysqr.com/
"           http://apt-blog.net
"
" VimRepress 
"    - A mod of a mod of a mod of Vimpress.   
"    - A vim plugin fot writting your wordpress blog.
"    - Write with Markdown, control posts format precisely.
"    - Stores Markdown rawtext in wordpress custom fields.
"
" Version:     3.2.0
"
" Config: Create account configure as `~/.vimpressrc' in the following
" format:
"
"[Blog0]
"blog_url = http://a-blog.com/
"username = admin
"password = 123456
"
"[Blog1]
"blog_url = https://someone.wordpress.com/
"username = someone
"password =
"
"[Blog2]
"blog_url = https://someone.wordpress.com/
"username = someone
"passwordcmd = 'keyring get blog user' 
"

"#######################################################################

if !has("python")
    finish
endif

function! CompSave(ArgLead, CmdLine, CursorPos)
  return "publish\ndraft\n"
endfunction

function! CompPrev(ArgLead, CmdLine, CursorPos)
  return "local\npublish\ndraft\n"
endfunction

function! CompEditType(ArgLead, CmdLine, CursorPos)
  return "post\npage\n"
endfunction

command! -nargs=? -complete=custom,CompEditType BlogList exec('py blog_list(<f-args>)')
command! -nargs=? -complete=custom,CompEditType BlogNew exec('py blog_new(<f-args>)')
command! -nargs=? -complete=custom,CompSave BlogSave exec('py blog_save(<f-args>)')
command! -nargs=? -complete=custom,CompPrev BlogPreview exec('py blog_preview(<f-args>)')
command! -nargs=1 -complete=file BlogUpload exec('py blog_upload_media(<f-args>)')
command! -nargs=1 BlogOpen exec('py blog_guess_open(<f-args>)')
command! -nargs=? BlogSwitch exec('py blog_config_switch(<f-args>)')
command! -nargs=? BlogCode exec('py blog_append_code(<f-args>)')

python << EOF
# -*- coding: utf-8 -*-
import vim
import urllib
import xmlrpclib
import re
import os
import mimetypes
import webbrowser
import tempfile
import subprocess
from ConfigParser import SafeConfigParser

try:
    import markdown
except ImportError:
    try:
        import markdown2 as markdown
    except ImportError:
        class markdown_stub(object):
            def markdown(self, n):
                raise VimPressException("The package python-markdown is "
                        "required and is either not present or not properly "
                        "installed.")

        markdown = markdown_stub()


def exception_check(func):
    def __check(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except (VimPressException, AssertionError), e:
            echoerr(str(e))
        except (xmlrpclib.Fault, xmlrpclib.ProtocolError), e:
            if getattr(e, "faultString", None) is None:
                echoerr("xmlrpc error: %s" % e)
            else:
                echoerr("xmlrpc error: %s" % e.faultString.encode("utf-8"))
        except IOError, e:
            echoerr("network error: %s" % e)
        except Exception, e:
            echoerr("something wrong: %s" % e)
            raise

    return __check

echomsg = lambda s: vim.command('echomsg "%s"' % s)
echoerr = lambda s: vim.command('echoerr "%s"' % s)

################################################
# Helper Classes
#################################################


class VimPressException(Exception):
    pass


class DataObject(object):

    #CONST
    DEFAULT_LIST_COUNT = "15"
    IMAGE_TEMPLATE = '<a href="%(url)s">' \
                     '<img title="%(file)s" alt="%(file)s" src="%(url)s"' \
                     'class="aligncenter" /></a>'
    MARKER = dict(bg="=========== Meta ============",
              mid="=============================",
              ed="========== Content ==========",
              more='"====== Press Here for More ======',
              list_title='"====== '
                '%(edit_type)s List in %(blog_url)s =========')

    LIST_VIEW_KEY_MAP = dict(enter="<enter>", delete="<delete>")
    CUSTOM_FIELD_KEY = "mkd_text"

    #Temp variables.
    __xmlrpc = None
    __conf_index = 0
    __config = None

    view = 'edit'
    vimpress_temp_dir = ''

    blog_username = property(lambda self: self.xmlrpc.username)
    blog_url = property(lambda self: self.xmlrpc.blog_url)
    conf_index = property(lambda self: self.__conf_index)
    current_post_id = property(lambda self: self.xmlrpc.current_post_id,
            lambda self, d: setattr(self.xmlrpc, "current_post_id", d))
    post_cache = property(lambda self: self.xmlrpc.post_cache)

    @property
    def current_post(self):
        post_id = self.current_post_id
        post = self.post_cache.get(post_id)
        if post is None and post_id == '':
            post = ContentStruct()
            if post.post_id != '':
                self.current_post_id = post.post_id
                self.current_post = post
            else:
                self.post_cache[''] = post

        assert post is not None, "current_post, no way to return None"
        return post

    @current_post.setter
    def current_post(self, data):
        post_id = str(data.post_id)

         # New post, just post first time
        if self.current_post_id == '' and \
                post_id != '' and '' in self.post_cache:
            self.post_cache.pop('')
        self.current_post_id = post_id
        if post_id not in self.post_cache:
            self.post_cache[post_id] = data

    @conf_index.setter
    def conf_index(self, index):
        try:
            index = int(index)
        except ValueError:
            raise VimPressException("Invalid Index: %s" % index)

         #auto increase
        if index < 0:
            self.__conf_index += 1
            if self.__conf_index >= len(self.config):
                self.__conf_index = 0
         # user enter index
        else:
            assert index < len(self.config), "Invalid Index: %d" % index
            self.__conf_index = index

        self.__xmlrpc = None

    @property
    def xmlrpc(self):
        if self.__xmlrpc is None:
            conf_index = self.conf_index
            config = self.config[conf_index]

            if "xmlrpc_obj" not in config:
                try:
                    blog_username = config['username']
                    blog_url = config['blog_url']
                    if 'password' in config:
                         blog_password=config.get('password','')
                         if blog_password == '':
                              blog_password = vim_input(
                                 "Enter password for %s" % blog_url, True)
                    else:
                         password_cmd=config['password_cmd']
                         blog_password=subprocess.check_output(password_cmd,shell=True)
                         blog_password=blog_password.rstrip()
                except KeyError, e:
                    raise VimPressException("Configuration error: %s" % e)
                echomsg("Connecting to '%s' ... " % blog_url)
                config["xmlrpc_obj"] = wp_xmlrpc(blog_url,
                        blog_username, blog_password)

            self.__xmlrpc = config["xmlrpc_obj"]

            # Setting tags and categories for completefunc
            categories = config.get("categories", None)
            if categories is None:
                categories = [i["description"].encode("utf-8")
                        for i in self.xmlrpc.get_categories()]
                config["categories"] = categories

            vim.command('let s:completable = "%s"' % '|'.join(categories))
            echomsg("done.")
        return self.__xmlrpc

    @property
    def config(self):
        if self.__config is None or len(self.__config) == 0:

            confpsr = SafeConfigParser()
            confile = os.path.expanduser("~/.vimpressrc")
            conf_options = ("blog_url", "username","password", "password_cmd")

            if os.path.exists(confile):
                conf_list = []
                confpsr.read(confile)
                for sec in confpsr.sections():
                    sec_options=[i for i in conf_options if confpsr.has_option(sec,i)]
                    values = [confpsr.get(sec, i) for i in sec_options]
                    conf_list.append(dict(zip(sec_options, values)))
                if len(conf_list) > 0:
                    self.__config = conf_list
                else:
                    raise VimPressException(
                            "You have an empty `~/.vimpressrc', "
                            "thus no configuration will be read. "
                            "If you still have your account info in "
                            "`.vimrc', remove `~/.vimpressrc' and "
                            "try again.")
            else:
                try:
                    self.__config = vim.eval("VIMPRESS")
                except vim.error:
                    pass
                else:
                    # write config to `~/.vimpressrc`,
                    # coding account in .vimrc is obsolesced.
                    if not os.path.exists(confile) and \
                            self.__config is not None:
                        with open(confile, 'w') as f:
                            for i, c in enumerate(self.__config):
                                sec = "Blog%d" % i
                                confpsr.add_section(sec)
                                for i in conf_options:
                                    confpsr.set(sec, i, c.get(i, ''))
                            confpsr.write(f)

                        echomsg("Your Blog accounts are now copied to "
                                "`~/.vimpressrc', definding account info "
                                "in `.vimrc` is now obsolesced, and may "
                                "lead to secret leak if you share your "
                                "vim configuration with public. Please "
                                "REMOVE the `let VIMPRESS =' code in your "
                                "`.vimrc'. ")

            if self.__config is None or len(self.__config) == 0:
                raise VimPressException("Could not find vimpress "
                        "configuration. Please read ':help vimpress' "
                        "for more information.")

        return self.__config


class wp_xmlrpc(object):

    def __init__(self, blog_url, username, password):
        self.blog_url = blog_url
        self.username = username
        self.password = password
        p = xmlrpclib.ServerProxy(os.path.join(blog_url, "xmlrpc.php"))
        self.mw_api = p.metaWeblog
        self.wp_api = p.wp
        self.mt_api = p.mt
        self.demo_api = p.demo

        assert self.demo_api.sayHello() == "Hello!", \
                    "XMLRPC Error with communication with '%s'@'%s'" % \
                    (username, blog_url)

        self.cache_reset()
        self.post_cache = dict()

        self.current_post_id = ''

    def cache_reset(self):
        self.__cache_post_titles = []
        self.__post_title_max = False

    def cache_remove_post(self, postid):
        for p in self.__cache_post_titles:
            if p["postid"] == str(postid):
                self.__cache_post_titles.remove(p)
                break

    is_reached_title_max = property(lambda self: self.__post_title_max)

    new_post = lambda self, post_struct: self.mw_api.newPost('',
            self.username, self.password, post_struct)

    get_post = lambda self, post_id: self.mw_api.getPost(post_id,
            self.username, self.password)

    edit_post = lambda self, post_id, post_struct: \
            self.mw_api.editPost(post_id, self.username,
                    self.password, post_struct)

    delete_post = lambda self, post_id: self.mw_api.deletePost('',
            post_id, self.username, self.password, '')

    def get_recent_post_titles(self, retrive_count=0):
        if retrive_count > len(self.__cache_post_titles) and \
                not self.is_reached_title_max:
            self.__cache_post_titles = self.mt_api.getRecentPostTitles('',
                    self.username, self.password, retrive_count)
            if len(self.__cache_post_titles) < retrive_count:
                self.__post_title_max = True

        return self.__cache_post_titles

    get_categories = lambda self: self.mw_api.getCategories('',
            self.username, self.password)

    new_media_object = lambda self, object_struct: \
            self.mw_api.newMediaObject('', self.username,
            self.password, object_struct)

    get_page = lambda self, page_id: self.wp_api.getPage('',
            page_id, self.username, self.password)

    delete_page = lambda self, page_id: self.wp_api.deletePage('',
            self.username, self.password, page_id)

    get_page_list = lambda self: self.wp_api.getPageList('',
            self.username, self.password)


class ContentStruct(object):

    buffer_meta = None
    post_struct_meta = None
    EDIT_TYPE = ''

    @property
    def META_TEMPLATE(self):
        KEYS_BASIC = ("StrID", "Title", "Slug")
        KEYS_EXT = ("Cats", "Tags")
        KEYS_BLOG = ("EditType", "EditFormat", "BlogAddr")

        pt = ['"{k:<6}: {{{t}}}'.format(k=p, t=p.lower()) for p in KEYS_BASIC]
        if self.EDIT_TYPE == "post":
            pt.extend(['"{k:<6}: {{{t}}}'.format(k=p, t=p.lower())
                    for p in KEYS_EXT])
        pm = "\n".join(pt)
        bm = "\n".join(['"{k:<11}: {{{t}}}'.format(k=p, t=p.lower())
            for p in KEYS_BLOG])
        return u'"{bg}\n{0}\n"{mid}\n{1}\n"{ed}\n'.format(pm, bm, **G.MARKER)

    POST_BEGIN = property(lambda self: len(self.META_TEMPLATE.splitlines()))
    raw_text = ''
    html_text = ''

    def __init__(self, edit_type=None, post_id=None):

        self.EDIT_TYPE = edit_type
        self.buffer_meta = dict(strid='', edittype=edit_type,
                blogaddr=g_data.blog_url)

        self.post_struct_meta = dict(title='',
                wp_slug='',
                post_type=edit_type,
                description='',
                custom_fields=[],
                post_status='draft')

        if post_id is not None:
            self.refresh_from_wp(post_id)

        if self.EDIT_TYPE is None:
            self.parse_buffer()

    def parse_buffer(self):
        start = 0
        while not vim.current.buffer[start][1:].startswith(G.MARKER['bg']):
            start += 1

        end = start + 1
        while not vim.current.buffer[end][1:].startswith(G.MARKER['ed']):
            if not vim.current.buffer[end].startswith('"===='):
                line = vim.current.buffer[end][1:].strip().split(":")
                k, v = line[0].strip().lower(), ':'.join(line[1:])
                self.buffer_meta[k.strip().lower()] = v.strip().decode('utf-8')
            end += 1

        if self.EDIT_TYPE != self.buffer_meta["edittype"]:
            self.EDIT_TYPE = self.buffer_meta["edittype"]

        self.buffer_meta["content"] = '\n'.join(
                vim.current.buffer[end + 1:]).decode('utf-8')

    def fill_buffer(self):
        meta = dict(strid="", title="", slug="",
                cats="", tags="", editformat="HTML", edittype="")
        meta.update(self.buffer_meta)
        meta_text = self.META_TEMPLATE.format(**meta)\
                .encode('utf-8').splitlines()
        vim.current.buffer[0] = meta_text[0]
        vim.current.buffer.append(meta_text[1:])
        content = self.buffer_meta.get("content", ' ')\
                .encode('utf-8').splitlines()
        vim.current.buffer.append(content)

    def update_buffer_meta(self):
        """
        Updates the meta data region of a blog editing buffer.
        @params **kwargs - keyworded arguments
        """
        kw = self.buffer_meta
        start = 0
        while not vim.current.buffer[start][1:].startswith(G.MARKER['bg']):
            start += 1

        end = start + 1
        while not vim.current.buffer[end][1:].startswith(G.MARKER['ed']):
            if not vim.current.buffer[end].startswith('"===='):
                line = vim.current.buffer[end][1:].strip().split(":")
                k, v = line[0].strip().lower(), ':'.join(line[1:])
                if k in kw:
                    new_line = u"\"%s: %s" % (line[0], kw[k])
                    vim.current.buffer[end] = new_line.encode('utf-8')
            end += 1

    def refresh_from_buffer(self):
        self.parse_buffer()

        meta = self.buffer_meta
        struct = self.post_struct_meta

        struct.update(title=meta["title"],
                wp_slug=meta["slug"], post_type=self.EDIT_TYPE)

        if self.EDIT_TYPE == "post":
            struct.update(categories=meta["cats"].split(','),
                    mt_keywords=meta["tags"].split(','))

        self.rawtext = rawtext = meta["content"]

        #Translate markdown and save in custom fields.
        if meta["editformat"].lower() == "markdown":
            for f in struct["custom_fields"]:
                if f["key"] == G.CUSTOM_FIELD_KEY:
                    f["value"] = rawtext
                    break
             # Not found, add new custom field.
            else:
                field = dict(key=G.CUSTOM_FIELD_KEY, value=rawtext)
                struct["custom_fields"].append(field)

            struct["description"] = self.html_text = markdown.markdown(rawtext)
        else:
            struct["description"] = self.html_text = rawtext

    def refresh_from_wp(self, post_id):
         # get from wp
        self.post_struct_meta = struct = getattr(g_data.xmlrpc,
                "get_" + self.EDIT_TYPE)(post_id)

         # struct buffer meta
        meta = dict(editformat="HTML",
                title=struct["title"],
                slug=struct["wp_slug"])

        if self.EDIT_TYPE == "post":
            meta.update(strid=str(struct["postid"]),
            cats=", ".join(struct["categories"]),
            tags=struct["mt_keywords"])
            MORE_KEY = "mt_text_more"
        else:
            meta.update(strid=str(struct["page_id"]))
            MORE_KEY = "text_more"

        self.html_text = content = struct["description"]

         #detect more text
        post_more = struct.get(MORE_KEY, '')
        if len(post_more) > 0:
            content += u'<!--more-->' + post_more
            struct[MORE_KEY] = ''
            self.html_text = struct["description"] = content

         #Use Markdown text if exists in custom fields
        for field in struct["custom_fields"]:
            if field["key"] == G.CUSTOM_FIELD_KEY:
                meta['editformat'] = "HTML"
                self.raw_text = content = field["value"]
                break
        else:
            self.raw_text = content

        meta["content"] = content

        self.buffer_meta.update(meta)

    def save_post(self):
        ps = self.post_struct_meta
        if self.EDIT_TYPE == "post":
            if ps.get("postid", '') == '' and self.post_id == '':
                post_id = g_data.xmlrpc.new_post(ps)
            else:
                post_id = ps["postid"] if "postid" in ps \
                        else int(self.post_id)
                g_data.xmlrpc.edit_post(post_id, ps)
        else:
            if ps.get("page_id", '') == '' and self.post_id == '':
                post_id = g_data.xmlrpc.new_post(ps)
            else:
                post_id = ps["page_id"] if "page_id" in ps \
                        else int(self.post_id)
                g_data.xmlrpc.edit_post(post_id, ps)

        self.refresh_from_wp(post_id)

    post_status = property(lambda self:
            self.post_struct_meta[self.EDIT_TYPE + "_status"])

    @post_status.setter
    def post_status(self, data):
        if data is not None:
            self.post_struct_meta[self.EDIT_TYPE + "_status"] = data

    post_id = property(lambda self: self.buffer_meta["strid"])

    def html_preview(self):
        """
        Opens a browser with a local preview of the content.
        @params text_html - the html content
                meta      - a dictionary of the meta data
        """
        if g_data.vimpress_temp_dir == '':
            g_data.vimpress_temp_dir = tempfile.mkdtemp(suffix="vimpress")

        html = \
                u"""<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd"><html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"> <title>Vimpress Local Preview: %(title)s</title> <style type="text/css"> ul, li { margin: 1em; } :link,:visited { text-decoration:none } h1,h2,h3,h4,h5,h6,pre,code { font-size:1.1em; } h1 {font-size: 1.8em;} h2 {font-size: 1.5em;} h3{font-size: 1.3em;} h4{font-size: 1.2em;} h5 {font-size: 1.1em;} a img,:link img,:visited img { border:none } body { margin:0 auto; width:770px; font-family: Helvetica, Arial, Sans-serif; font-size:12px; color:#444; } </style> </meta> </head> <body> %(content)s </body> </html>
""" % dict(content=self.html_text, title=self.buffer_meta["title"])
        with open(os.path.join(
                g_data.vimpress_temp_dir, "vimpress_temp.html"), 'w') as f:
            f.write(html.encode('utf-8'))
        webbrowser.open("file://%s" % f.name)

    def remote_preview(self, pub="draft"):
        self.post_status = pub
        self.save_post()
        webbrowser.open("%s?p=%s&preview=true" %
                (g_data.blog_url, self.post_id))


#################################################
# Golbal Variables
#################################################
G = DataObject
g_data = DataObject()

#################################################
# Helper Functions
#################################################


def vim_encoding_check(func):
    """
    Decorator.
    Check vim environment. wordpress via xmlrpc only support unicode data,
    setting vim to utf-8 for all data compatible.
    """
    def __check(*args, **kw):
        orig_enc = vim.eval("&encoding")
        if orig_enc is None:
            echomsg("Failed to detech current vim encoding. Make sure your"
                    " content encoded in UTF-8 to have vimpress work "
                    "correctly.")
        elif orig_enc != "utf-8":
            modified = vim.eval("&modified")
            buf_list = '\n'.join(vim.current.buffer).decode(orig_enc).encode('utf-8').splitlines()
            del vim.current.buffer[:]
            vim.command("setl encoding=utf-8")
            vim.current.buffer[0] = buf_list[0]
            if len(buf_list) > 1:
                vim.current.buffer.append(buf_list[1:])
            if modified == '0':
                vim.command('setl nomodified')
        return func(*args, **kw)
    return __check


def view_switch(view = "", assert_view = "", reset = False):
    """
    Decorator.
    For commands to switch between edit/list view, data/status need to be configured.
    """
    def switch(func):
        def __run(*args, **kw):
            if assert_view != '':
                if g_data.view != assert_view:
                    raise VimPressException("Command only available at '%s' view." % assert_view)

            if func.func_name == "blog_new":
                if g_data.view == "list":
                    kw["currentContent"] = ['']
                else:
                    kw["currentContent"] = vim.current.buffer[:]
            elif func.func_name == "blog_config_switch":
                if g_data.view == "list":
                    kw["refresh_list"] = True

            if reset:
                g_data.xmlrpc.cache_reset()

            if view != '':
                #Switching view
                if g_data.view != view:

                    #from list view
                    if g_data.view == "list":
                        for v in g_data.LIST_VIEW_KEY_MAP.values():
                            if vim.eval("mapcheck('%s')" % v):
                                vim.command('unmap <buffer> %s' % v)

                    g_data.view = view

            return func(*args, **kw)
        return __run
    return switch


def blog_wise_open_view():
    """
    Wisely decides whether to wipe out the content of current buffer or open a new splited window.
    """
    if vim.current.buffer.name is None and \
            (vim.eval('&modified') == '0' or
                len(vim.current.buffer) == 1):
        vim.command('setl modifiable')
        del vim.current.buffer[:]
        vim.command('setl nomodified')
    else:
        vim.command(":new")
    vim.command('setl syntax=blogsyntax')
    vim.command('setl completefunc=Completable')


@vim_encoding_check
def vim_input(message = 'input', secret = False):
    vim.command('call inputsave()')
    vim.command("let user_input = %s('%s :')" % (("inputsecret" if secret else "input"), message))
    vim.command('call inputrestore()')
    return vim.eval('user_input')


#################################################
# Command Functions
#################################################

@exception_check
@vim_encoding_check
@view_switch(assert_view = "edit", reset = True)
def blog_save(pub = None):
    """
    Saves the current editing buffer.
    @params pub - either "draft" or "publish"
    """
    if pub not in ("publish", "draft", None):
        raise VimPressException(":BlogSave draft|publish")
    cp = g_data.current_post
    assert cp is not None, "Can't get current post obj."
    cp.refresh_from_buffer()

    if cp.buffer_meta["blogaddr"] != g_data.blog_url and cp.post_id != '':
        confirm = vim_input("Are u sure saving it to \"%s\" ? BlogAddr in current buffer does NOT matched. \nStill saving it ? (may cause data lost) [yes/NO]" % g_data.blog_url)
        assert confirm.lower() == 'yes', "Aborted."

    cp.post_status = pub
    cp.save_post()
    cp.update_buffer_meta()
    g_data.current_post = cp
    notify = "%s ID=%s saved with status '%s'" % (cp.post_status, cp.post_id, cp.post_status)
    echomsg(notify)
    vim.command('setl nomodified')


@exception_check
@vim_encoding_check
@view_switch(view = "edit")
def blog_new(edit_type = "post", currentContent = None):
    """
    Creates a new editing buffer of specified type.
    @params edit_type - either "post" or "page"
    """
    if edit_type.lower() not in ("post", "page"):
        raise VimPressException("Invalid option: %s " % edit_type)
    blog_wise_open_view()
    g_data.current_post = ContentStruct(edit_type = edit_type)
    cp = g_data.current_post
    cp.fill_buffer()


@view_switch(view = "edit")
def blog_edit(edit_type, post_id):
    """
    Opens a new editing buffer with blog content of specified type and id.
    @params edit_type - either "post" or "page"
            post_id   - the id of the post or page
    """
    blog_wise_open_view()
    if edit_type.lower() not in ("post", "page"):
        raise VimPressException("Invalid option: %s " % edit_type)
    post_id = str(post_id)

    if post_id in g_data.post_cache:
        cp = g_data.current_post = g_data.post_cache[post_id]
    else:
        cp = g_data.current_post = ContentStruct(edit_type = edit_type, post_id = post_id)

    cp.fill_buffer()
    vim.current.window.cursor = (cp.POST_BEGIN, 0)
    vim.command('setl nomodified')
    vim.command('setl textwidth=0')
    for v in G.LIST_VIEW_KEY_MAP.values():
        if vim.eval("mapcheck('%s')" % v):
            vim.command('unmap <buffer> %s' % v)


@view_switch(assert_view = "list")
def blog_delete(edit_type, post_id):
    """
    Deletes a page or post of specified id.
    @params edit_type - either "page" or "post"
            post_id   - the id of the post or page
    """
    if edit_type.lower() not in ("post", "page"):
        raise VimPressException("Invalid option: %s " % edit_type)
    deleted = getattr(g_data.xmlrpc, "delete_" + edit_type)(post_id)
    assert deleted is True, "There was a problem deleting the %s." % edit_type
    echomsg("Deleted %s id %s. " % (edit_type, str(post_id)))
    g_data.xmlrpc.cache_remove_post(post_id)
    blog_list(edit_type)


@exception_check
@view_switch(assert_view = "list")
def blog_list_on_key_press(action, edit_type):
    """
    Calls blog open on the current line of a listing buffer.
    """
    if action.lower() not in ("open", "delete"):
        raise VimPressException("Invalid option: %s" % action)

    row = vim.current.window.cursor[0]
    line = vim.current.buffer[row - 1]
    id = line.split()[0]
    title = line[len(id):].strip()

    try:
        int(id)
    except ValueError:
        if line.find("More") != -1:
            assert g_data.xmlrpc.is_reached_title_max is False, "No more posts."
            vim.command("setl modifiable")
            del vim.current.buffer[len(vim.current.buffer) - 1:]
            append_blog_list(edit_type)
            vim.current.buffer.append(G.MARKER['more'])
            vim.command("setl nomodified")
            vim.command("setl nomodifiable")
            return
        else:
            raise VimPressException("Move cursor to a post/page line and press Enter.")

    if len(title) > 30:
        title = title[:30] + ' ...'

    if action.lower() == "delete":
        confirm = vim_input("Confirm Delete [%s]: %s? [yes/NO]" % (id, title))
        assert confirm.lower() == 'yes', "Delete Aborted."

    vim.command("setl modifiable")
    del vim.current.buffer[:]
    vim.command("setl nomodified")

    if action == "open":
        blog_edit(edit_type, int(id))
    elif action == "delete":
        blog_delete(edit_type, int(id))


def append_blog_list(edit_type, count = G.DEFAULT_LIST_COUNT):
    if edit_type.lower() == "post":
        current_posts = len(vim.current.buffer) - 1
        retrive_count = int(count) + current_posts
        posts_titles = g_data.xmlrpc.get_recent_post_titles(retrive_count)

        vim.current.buffer.append(
                [(u"%(postid)s\t%(title)s" % p).encode('utf-8')
                    for p in posts_titles[current_posts:]])
    else:
        pages = g_data.xmlrpc.get_page_list()
        vim.current.buffer.append(
            [(u"%(page_id)s\t%(page_title)s" % p).encode('utf-8') for p in pages])


@exception_check
@vim_encoding_check
@view_switch(view = "list")
def blog_list(edit_type = "post", keep_type = False):
    """
    Creates a listing buffer of specified type.
    @params edit_type - either "post(s)" or "page(s)"
    """
    if keep_type:
        first_line = vim.current.buffer[0]
        assert first_line.find("List") != -1, "Failed to detect current list type."
        edit_type = first_line.split()[1].lower()

    blog_wise_open_view()
    vim.current.buffer[0] = G.MARKER["list_title"] % \
                                dict(edit_type = edit_type.capitalize(), blog_url = G.blog_url)

    if edit_type.lower() not in ("post", "page"):
        raise VimPressException("Invalid option: %s " % edit_type)

    append_blog_list(edit_type, G.DEFAULT_LIST_COUNT)

    if edit_type == "post":
        vim.current.buffer.append(G.MARKER['more'])

    vim.command("setl nomodified")
    vim.command("setl nomodifiable")
    vim.current.window.cursor = (2, 0)
    vim.command("map <silent> <buffer> %(enter)s :py blog_list_on_key_press('open', '%%s')<cr>"
            % G.LIST_VIEW_KEY_MAP % edit_type)
    vim.command("map <silent> <buffer> %(delete)s :py blog_list_on_key_press('delete', '%%s')<cr>"
            % G.LIST_VIEW_KEY_MAP % edit_type)


@exception_check
@vim_encoding_check
@view_switch(assert_view = "edit")
def blog_upload_media(file_path):
    """
    Uploads a file to the blog.
    @params file_path - the file's path
    """
    if not os.path.exists(file_path):
        raise VimPressException("File does not exist: %s" % file_path)

    name = os.path.basename(file_path)
    filetype = mimetypes.guess_type(file_path)[0]
    with open(file_path) as f:
        bits = xmlrpclib.Binary(f.read())

    result = g_data.xmlrpc.new_media_object(dict(name = name, type = filetype, bits = bits))

    ran = vim.current.range
    if filetype.startswith("image"):
        img = G.IMAGE_TEMPLATE % result
        ran.append(img)
    else:
        ran.append(result["url"])
    ran.append('')


@exception_check
@vim_encoding_check
@view_switch(assert_view = "edit")
def blog_append_code(code_type = ""):
    html = \
"""<pre lang="%s"%s>
</pre>"""
    if code_type == "":
        code_type = ("text", "")
    else:
        code_type = (code_type, ' line="1"')
    html = html % code_type
    row, col = vim.current.window.cursor
    code_block = html.splitlines()
    vim.current.range.append(code_block)
    vim.current.window.cursor = (row + len(code_block), 0)


@exception_check
@vim_encoding_check
@view_switch(assert_view = "edit")
def blog_preview(pub = "local"):
    """
    Opens a browser window displaying the content.
    @params pub - If "local", the content is shown in a browser locally.
                  If "draft", the content is saved as a draft and previewed remotely.
                  If "publish", the content is published and displayed remotely.
    """
    cp = g_data.current_post
    cp.refresh_from_buffer()
    if pub == "local":
        cp.html_preview()
    elif pub in ("publish", "draft"):
        cp.remote_preview(pub)
        if pub == "draft":
            echomsg("You have to login in the browser to preview the post when save as draft.")
    else:
        raise VimPressException("Invalid option: %s " % pub)


@exception_check
def blog_guess_open(what):
    """
    Tries several methods to get the post id from different user inputs, such as args, url, postid etc.
    """
    post_id = ''
    blog_index = -1
    if type(what) is str:

        for i, p in enumerate(vim.eval("VIMPRESS")):
            if what.startswith(p["blog_url"]):
                blog_index = i

        # User input a url contained in the profiles
        if blog_index != -1:
            guess_id = re.search(r"\S+?p=(\d+)$", what)

            # permantlinks
            if guess_id is None:

                # try again for /archives/%post_id%
                guess_id = re.search(r"\S+/archives/(\d+)", what)

                # fail,  try get full link from headers
                if guess_id is None:
                    headers = urllib.urlopen(what).headers.headers
                    for link in headers:
                        if link.startswith("Link:"):
                            post_id = re.search(r"<\S+?p=(\d+)>", link).group(1)

                else:
                    post_id = guess_id.group(1)

            # full link with ID (http://blog.url/?p=ID)
            else:
                post_id = guess_id.group(1)

            # detected something ?
            assert post_id != '', "Failed to get post/page id from '%s'." % what

             #switch view if needed.
            if blog_index != -1 and blog_index != g_data.conf_index:
                blog_config_switch(blog_index)

        # Uesr input something not a usabe url, try numberic
        else:
            try:
                post_id = str(int(what))
            except ValueError:
                raise VimPressException("Failed to get post/page id from '%s'." % what)

        blog_edit("post", post_id)


@exception_check
@vim_encoding_check
@view_switch()
def blog_config_switch(index = -1, refresh_list = False):
    """
    Switches the blog to the 'index' of the configuration array.
    """
    g_data.conf_index = index
    if refresh_list:
        blog_list(keep_type = True)
    echomsg("Vimpress switched to '%s'@'%s'" % (g_data.blog_username, g_data.blog_url))
