// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssr_cfg.h - ssr.cfg, the one file that describes the cluster. INI: [section]
 * lines, key = value lines, # comments. ssrd and ssrctl both read it; the
 * file itself documents the keys.
 */
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>

struct Cfg {
    std::map<std::string, std::map<std::string, std::string>> s;   // s[section][key] = value

    static Cfg load(const char *path)
    {
        Cfg c;
        std::ifstream f(path);
        if (!f) {
            fprintf(stderr, "cannot open %s\n", path);
            exit(2);
        }
        std::string line, sec;
        while (std::getline(f, line)) {
            if (size_t h = line.find('#'); h != std::string::npos)
                line.erase(h);
            line.erase(std::remove_if(line.begin(), line.end(), ::isspace), line.end());
            if (line.empty())
                continue;
            if (line.front() == '[' && line.back() == ']') {
                sec = line.substr(1, line.size() - 2);
                continue;
            }
            size_t eq = line.find('=');
            if (eq != std::string::npos)
                c.s[sec][line.substr(0, eq)] = line.substr(eq + 1);
        }
        return c;
    }

    /* A missing key is an error: the file is the whole configuration. */
    const std::string &get(const std::string &sec, const std::string &key) const
    {
        auto i = s.find(sec);
        if (i == s.end() || !i->second.count(key)) {
            fprintf(stderr, "ssr.cfg: no '%s' in [%s]\n", key.c_str(), sec.c_str());
            exit(2);
        }
        return i->second.at(key);
    }

    long long num(const std::string &sec, const std::string &key) const
    {
        return strtoll(get(sec, key).c_str(), nullptr, 0);
    }
};
